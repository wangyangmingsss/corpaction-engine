// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IValidatorManager} from "../interfaces/IValidatorManager.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

contract ValidatorManager is
    IValidatorManager,
    ICorpActionTypes,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(address => bool) private _validators;
    address[] private _validatorList;
    uint256 private _validatorCount;

    // Quorum configuration per severity level
    // Severity 1 (Low): TICKER_CHANGE -> 2-of-3
    // Severity 2 (Medium): DIVIDEND, FORWARD_SPLIT, REVERSE_SPLIT -> 3-of-5
    // Severity 3 (High): MERGER_*, SPINOFF, DELISTING, LIQUIDATION -> 4-of-5
    mapping(ActionType => uint256) private _quorums;
    uint256 private _superMajority; // For emergency resume (4-of-5)

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event QuorumUpdated(ActionType indexed actionType, uint256 quorum);
    event SuperMajorityUpdated(uint256 superMajority);

    error AlreadyValidator(address account);
    error NotValidator(address account);
    error InvalidSignature();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address[] calldata initialValidators,
        uint256 superMajority
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        for (uint256 i = 0; i < initialValidators.length; i++) {
            _addValidator(initialValidators[i]);
        }

        _superMajority = superMajority;

        // Default quorums
        _quorums[ActionType.TICKER_CHANGE] = 2;
        _quorums[ActionType.DIVIDEND] = 3;
        _quorums[ActionType.FORWARD_SPLIT] = 3;
        _quorums[ActionType.REVERSE_SPLIT] = 3;
        _quorums[ActionType.MERGER_CASH] = 4;
        _quorums[ActionType.MERGER_STOCK] = 4;
        _quorums[ActionType.MERGER_HYBRID] = 4;
        _quorums[ActionType.SPINOFF] = 4;
        _quorums[ActionType.DELISTING] = 4;
        _quorums[ActionType.LIQUIDATION] = 4;
    }

    // ========== VALIDATOR MANAGEMENT ==========

    function addValidator(address account) external onlyRole(ADMIN_ROLE) {
        _addValidator(account);
    }

    function removeValidator(address account) external onlyRole(ADMIN_ROLE) {
        if (!_validators[account]) revert NotValidator(account);
        _validators[account] = false;
        _validatorCount--;

        for (uint256 i = 0; i < _validatorList.length; i++) {
            if (_validatorList[i] == account) {
                _validatorList[i] = _validatorList[_validatorList.length - 1];
                _validatorList.pop();
                break;
            }
        }

        emit ValidatorRemoved(account);
    }

    // ========== QUORUM MANAGEMENT ==========

    function setQuorum(
        ActionType actionType,
        uint256 quorum
    ) external onlyRole(ADMIN_ROLE) {
        require(quorum > 0 && quorum <= _validatorCount, "Invalid quorum");
        _quorums[actionType] = quorum;
        emit QuorumUpdated(actionType, quorum);
    }

    function setSuperMajority(uint256 superMajority) external onlyRole(ADMIN_ROLE) {
        require(superMajority > 0 && superMajority <= _validatorCount, "Invalid super majority");
        _superMajority = superMajority;
        emit SuperMajorityUpdated(superMajority);
    }

    // ========== QUERIES ==========

    function isValidator(address account) external view override returns (bool) {
        return _validators[account];
    }

    function getQuorum(ActionType actionType) external view override returns (uint256) {
        return _quorums[actionType];
    }

    function getSuperMajority() external view override returns (uint256) {
        return _superMajority;
    }

    function getValidatorCount() external view override returns (uint256) {
        return _validatorCount;
    }

    function getValidators() external view returns (address[] memory) {
        return _validatorList;
    }

    // ========== SIGNATURE VERIFICATION ==========

    function recoverSigner(
        bytes32 hash,
        bytes calldata signature
    ) external pure override returns (address) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(signature);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }

    // ========== INTERNAL ==========

    function _addValidator(address account) internal {
        if (_validators[account]) revert AlreadyValidator(account);
        _validators[account] = true;
        _validatorList.push(account);
        _validatorCount++;
        emit ValidatorAdded(account);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
