// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IActionRegistry} from "../interfaces/IActionRegistry.sol";
import {IValidatorManager} from "../interfaces/IValidatorManager.sol";
import {IActionExecutor} from "../interfaces/IActionExecutor.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";
import {IAttestationRegistry} from "../interfaces/IAttestationRegistry.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {TimelockController} from "./TimelockController.sol";
import {ActionLib} from "../libraries/ActionLib.sol";

contract ActionRegistry is
    IActionRegistry,
    ICorpActionTypes,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IValidatorManager public validatorManager;

    mapping(bytes32 => ActionIntent) private _intents;
    mapping(bytes32 => mapping(address => bool)) private _validations;
    mapping(bytes32 => uint256) private _validationCount;
    mapping(ActionType => address) private _executors;
    mapping(ActionType => uint256) private _timelocks;
    mapping(address => bytes32[]) private _tokenActions;
    bytes32[] private _allIntents;
    mapping(bytes32 => uint256) private _executionTime;

    uint256 public intentTTL;
    uint256 public queuedTTL;

    IFeeCollector public feeCollector;
    IAttestationRegistry public attestationRegistry;
    TimelockController public timelockController;

    /// @notice Maps old token addresses to new token addresses after ticker migrations
    mapping(address => address) public tokenMapping;

    event ActionProposed(bytes32 indexed intentId, ActionType indexed actionType,
        address indexed targetToken, string ticker);
    event ActionValidated(bytes32 indexed intentId, address validator,
        uint256 count, uint256 required);
    event ActionQueued(bytes32 indexed intentId, uint256 executionTime);
    event ActionExecuting(bytes32 indexed intentId);
    event ActionExecuted(bytes32 indexed intentId, ActionType indexed actionType,
        address indexed targetToken, bytes result);
    event ActionCancelled(bytes32 indexed intentId, string reason);
    event ActionReversed(bytes32 indexed intentId, string reason);
    event ActionFailed(bytes32 indexed intentId, string reason);
    event ExecutorRegistered(ActionType indexed actionType, address executor);
    event TimelockUpdated(ActionType indexed actionType, uint256 duration);
    event EmergencyPaused(address indexed triggeredBy);
    event EmergencyResumed(uint256 validatorCount);
    event ActionExpired(bytes32 indexed intentId);
    event FeeCollected(bytes32 indexed intentId, uint256 fee);
    event QuorumReached(bytes32 indexed intentId, ActionState state);
    event FeeCollectorUpdated(address feeCollector);
    event AttestationRegistryUpdated(address attestationRegistry);
    event QueuedTTLUpdated(uint256 ttl);
    event TimelockControllerUpdated(address timelockController);
    event TokenMappingUpdated(address indexed oldToken, address indexed newToken, bytes32 indexed intentId);

    error InvalidState(bytes32 intentId, ActionState current, ActionState expected);
    error InsufficientValidations(uint256 have, uint256 need);
    error TimelockNotExpired(bytes32 intentId, uint256 readyAt);
    error AlreadyValidated(bytes32 intentId, address validator);
    error IntentExpired(bytes32 intentId);
    error ExecutorNotRegistered(ActionType actionType);
    error IntentNotFound(bytes32 intentId);
    error DuplicateIntent(bytes32 intentId);
    error QueueExpired(bytes32 intentId);
    error AttestationNotVerified(bytes32 intentId, bytes32 attestationId);
    error ReverseQuorumNotMet(uint256 have, uint256 need);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address _validatorManager,
        uint256 _intentTTL
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        validatorManager = IValidatorManager(_validatorManager);
        intentTTL = _intentTTL;
        queuedTTL = 7 days;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    // ========== PROPOSE ==========

    function proposeAction(
        ActionIntent calldata intent,
        bytes calldata signature
    ) external whenNotPaused returns (bytes32 intentId) {
        intentId = intent.intentId;
        if (_intents[intentId].createdAt != 0) revert DuplicateIntent(intentId);

        address signer = validatorManager.recoverSigner(
            keccak256(abi.encode(intent)), signature
        );
        require(validatorManager.isValidator(signer), "Not a validator");

        _intents[intentId] = intent;
        _intents[intentId].state = ActionState.PROPOSED;
        _intents[intentId].createdAt = block.timestamp;
        _allIntents.push(intentId);
        _tokenActions[intent.targetToken].push(intentId);

        _validations[intentId][signer] = true;
        _validationCount[intentId] = 1;

        emit ActionProposed(intentId, intent.actionType,
            intent.targetToken, intent.ticker);

        _checkQuorum(intentId);
    }

    // ========== VALIDATE ==========

    function validateAction(
        bytes32 intentId,
        bytes calldata signature
    ) external whenNotPaused {
        ActionIntent storage intent = _getIntent(intentId);
        if (intent.state != ActionState.PROPOSED)
            revert InvalidState(intentId, intent.state, ActionState.PROPOSED);
        if (block.timestamp > intent.createdAt + intentTTL)
            revert IntentExpired(intentId);

        address signer = validatorManager.recoverSigner(
            keccak256(abi.encode(
                intentId, intent.actionType,
                intent.targetToken, intent.actionParams
            )),
            signature
        );
        require(validatorManager.isValidator(signer), "Not a validator");
        if (_validations[intentId][signer])
            revert AlreadyValidated(intentId, signer);

        _validations[intentId][signer] = true;
        _validationCount[intentId]++;

        uint256 required = validatorManager.getQuorum(intent.actionType);
        emit ActionValidated(intentId, signer,
            _validationCount[intentId], required);

        _checkQuorum(intentId);
    }

    // ========== QUEUE ==========

    function queueAction(bytes32 intentId) external whenNotPaused {
        ActionIntent storage intent = _getIntent(intentId);
        if (intent.state != ActionState.VALIDATED)
            revert InvalidState(intentId, intent.state, ActionState.VALIDATED);

        uint256 timelock;
        if (address(timelockController) != address(0)) {
            timelock = timelockController.getTimelock(intent.actionType);
        } else {
            timelock = _timelocks[intent.actionType];
        }
        intent.state = ActionState.QUEUED;
        _executionTime[intentId] = block.timestamp + timelock;
        emit ActionQueued(intentId, _executionTime[intentId]);
    }

    // ========== EXECUTE ==========

    function executeAction(
        bytes32 intentId
    ) external nonReentrant whenNotPaused {
        ActionIntent storage intent = _getIntent(intentId);
        if (intent.state != ActionState.QUEUED)
            revert InvalidState(intentId, intent.state, ActionState.QUEUED);
        if (block.timestamp < _executionTime[intentId])
            revert TimelockNotExpired(intentId, _executionTime[intentId]);
        if (queuedTTL > 0 && block.timestamp > _executionTime[intentId] + queuedTTL)
            revert QueueExpired(intentId);

        // Verify source attestation exists and is verified
        if (address(attestationRegistry) != address(0)) {
            bytes32 attId = intent.sourceAttestation;
            require(
                attestationRegistry.isVerified(attId),
                "Source attestation not verified"
            );
        }

        address executor = _executors[intent.actionType];
        if (executor == address(0))
            revert ExecutorNotRegistered(intent.actionType);

        // Collect fee before execution
        if (address(feeCollector) != address(0)) {
            uint256 fee = feeCollector.collectFee(intentId, intent.actionType, 0, address(0));
            emit FeeCollected(intentId, fee);
        }

        intent.state = ActionState.EXECUTING;
        emit ActionExecuting(intentId);

        try IActionExecutor(executor).execute(intent) returns (bytes memory result) {
            intent.state = ActionState.EXECUTED;
            intent.executedAt = block.timestamp;
            emit ActionExecuted(intentId, intent.actionType,
                intent.targetToken, result);
        } catch Error(string memory reason) {
            intent.state = ActionState.FAILED;
            emit ActionFailed(intentId, reason);
        } catch {
            intent.state = ActionState.FAILED;
            emit ActionFailed(intentId, "Unknown execution error");
        }
    }

    // ========== REVERSE ==========

    function reverseAction(
        bytes32 intentId,
        string calldata reason,
        bytes[] calldata signatures
    ) external whenNotPaused {
        ActionIntent storage intent = _getIntent(intentId);
        if (intent.state != ActionState.EXECUTED)
            revert InvalidState(intentId, intent.state, ActionState.EXECUTED);

        uint256 totalValidators = validatorManager.getValidatorCount();
        require(signatures.length >= totalValidators, "Need all validator signatures");

        bytes32 reverseHash = keccak256(
            abi.encodePacked("REVERSE_ACTION", intentId, reason)
        );

        uint256 validCount = 0;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = validatorManager.recoverSigner(
                reverseHash, signatures[i]
            );
            if (validatorManager.isValidator(signer)) validCount++;
        }
        if (validCount < totalValidators)
            revert ReverseQuorumNotMet(validCount, totalValidators);

        intent.state = ActionState.REVERSED;
        emit ActionReversed(intentId, reason);
    }

    // ========== EXPIRE ==========

    function expireAction(bytes32 intentId) external whenNotPaused {
        ActionIntent storage intent = _getIntent(intentId);
        if (intent.state == ActionState.PROPOSED) {
            require(
                block.timestamp > intent.createdAt + intentTTL,
                "Intent has not expired yet"
            );
        } else if (intent.state == ActionState.QUEUED) {
            require(
                queuedTTL > 0 && block.timestamp > _executionTime[intentId] + queuedTTL,
                "Queued action has not expired yet"
            );
        } else {
            revert InvalidState(intentId, intent.state, ActionState.PROPOSED);
        }

        intent.state = ActionState.EXPIRED;
        emit ActionExpired(intentId);
    }

    // ========== CANCEL ==========

    function cancelAction(
        bytes32 intentId,
        string calldata reason
    ) external {
        ActionIntent storage intent = _getIntent(intentId);
        require(ActionLib.isCancellableState(intent.state), "Cannot cancel in current state");
        require(validatorManager.isValidator(msg.sender), "Not a validator");

        intent.state = ActionState.CANCELLED;
        emit ActionCancelled(intentId, reason);
    }

    // ========== EMERGENCY ==========

    function emergencyPause() external {
        require(validatorManager.isValidator(msg.sender), "Not a validator");
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function emergencyResume(bytes[] calldata signatures) external {
        uint256 required = validatorManager.getSuperMajority();
        require(signatures.length >= required, "Insufficient signatures");

        bytes32 resumeHash = keccak256(
            abi.encodePacked("EMERGENCY_RESUME", block.chainid, address(this))
        );

        uint256 validCount = 0;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = validatorManager.recoverSigner(
                resumeHash, signatures[i]
            );
            if (validatorManager.isValidator(signer)) validCount++;
        }
        require(validCount >= required, "Not enough valid signatures");

        _unpause();
        emit EmergencyResumed(validCount);
    }

    // ========== ADMIN ==========

    function registerExecutor(
        ActionType actionType,
        address executor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _executors[actionType] = executor;
        emit ExecutorRegistered(actionType, executor);
    }

    function setTimelock(
        ActionType actionType,
        uint256 duration
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _timelocks[actionType] = duration;
        emit TimelockUpdated(actionType, duration);
    }

    function setFeeCollector(
        address _feeCollector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeCollector = IFeeCollector(_feeCollector);
        emit FeeCollectorUpdated(_feeCollector);
    }

    function setAttestationRegistry(
        address _attestationRegistry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        attestationRegistry = IAttestationRegistry(_attestationRegistry);
        emit AttestationRegistryUpdated(_attestationRegistry);
    }

    function setQueuedTTL(
        uint256 _queuedTTL
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        queuedTTL = _queuedTTL;
        emit QueuedTTLUpdated(_queuedTTL);
    }

    function setTimelockController(
        address _timelockController
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        timelockController = TimelockController(_timelockController);
        emit TimelockControllerUpdated(_timelockController);
    }

    /// @notice Updates the token mapping when a ticker migration replaces an old token with a new one.
    /// @dev Only callable by registered executor contracts.
    function updateTokenMapping(
        bytes32 intentId,
        address oldToken,
        address newToken
    ) external {
        // Verify caller is a registered executor
        bool isExecutor = false;
        // Check all action types to see if caller is a registered executor
        for (uint256 i = 0; i < 10; i++) {
            if (_executors[ActionType(i)] == msg.sender) {
                isExecutor = true;
                break;
            }
        }
        require(isExecutor, "Only registered executor");

        tokenMapping[oldToken] = newToken;
        emit TokenMappingUpdated(oldToken, newToken, intentId);
    }

    // ========== QUERIES ==========

    function getAction(bytes32 intentId)
        external view returns (ActionIntent memory) {
        return _intents[intentId];
    }

    function getActionsByToken(address token)
        external view returns (bytes32[] memory) {
        return _tokenActions[token];
    }

    function getValidationCount(bytes32 intentId)
        external view returns (uint256) {
        return _validationCount[intentId];
    }

    function getExecutionTime(bytes32 intentId)
        external view returns (uint256) {
        return _executionTime[intentId];
    }

    // ========== INTERNAL ==========

    function _checkQuorum(bytes32 intentId) internal {
        ActionIntent storage intent = _intents[intentId];
        uint256 required = validatorManager.getQuorum(intent.actionType);
        if (_validationCount[intentId] >= required) {
            intent.state = ActionState.VALIDATED;
            emit QuorumReached(intentId, ActionState.VALIDATED);
        }
    }

    function _getIntent(bytes32 intentId)
        internal view returns (ActionIntent storage) {
        if (_intents[intentId].createdAt == 0)
            revert IntentNotFound(intentId);
        return _intents[intentId];
    }

    function _authorizeUpgrade(address newImpl)
        internal override onlyRole(UPGRADER_ROLE) {}
}
