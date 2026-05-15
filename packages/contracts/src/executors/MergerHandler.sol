// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IActionExecutor} from "../interfaces/IActionExecutor.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

contract MergerHandler is
    IActionExecutor,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    enum MergerType { CASH_ONLY, STOCK_FOR_STOCK, HYBRID }

    struct MergerParams {
        MergerType mergerType;
        address acquiringToken;
        uint256 exchangeRatioNum;
        uint256 exchangeRatioDen;
        uint256 cashPerShare;
        address cashToken;
        uint256 electionDeadline;
        bool    hasElection;
        uint256 prorationFactor; // BPS
        bytes32 merkleRoot;
        uint256 totalCashPool;
    }

    struct MergerState {
        MergerParams params;
        bool initialized;
        uint256 totalCashClaimed;
        uint256 totalStockClaimed;
        bool completed;
    }

    address public actionRegistry;

    mapping(bytes32 => MergerState) public mergers;
    mapping(bytes32 => mapping(address => bool)) public mergerClaimed;
    /// @notice Elections: 0 = no election made, 1 = cash, 2 = stock
    mapping(bytes32 => mapping(address => uint8)) public mergerElections;

    event MergerInitiated(bytes32 indexed intentId, address indexed sourceToken,
        address indexed acquiringToken, MergerType mergerType);
    event MergerClaimed(bytes32 indexed intentId, address indexed claimer,
        uint256 cashAmount, uint256 stockAmount);
    event MergerElected(bytes32 indexed intentId, address indexed holder, uint8 option);
    event MergerFinalized(bytes32 indexed intentId);

    error MergerNotInitialized(bytes32 intentId);
    error AlreadyClaimed(bytes32 intentId, address claimer);
    error InvalidMerkleProof();
    error ElectionRequired(bytes32 intentId);
    error ElectionDeadlinePassed(bytes32 intentId);
    error ElectionDeadlineNotPassed(bytes32 intentId);
    error InvalidElectionOption(uint8 option);
    error InsufficientCashBalance(bytes32 intentId, uint256 required, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _registry) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        actionRegistry = _registry;
    }

    function execute(
        ICorpActionTypes.ActionIntent calldata intent
    ) external override returns (bytes memory) {
        require(msg.sender == actionRegistry, "Only registry");

        MergerParams memory params = abi.decode(
            intent.actionParams, (MergerParams)
        );

        mergers[intent.intentId] = MergerState({
            params: params,
            initialized: true,
            totalCashClaimed: 0,
            totalStockClaimed: 0,
            completed: false
        });

        // Validate cash pool: ensure contract holds enough cashToken
        if (params.totalCashPool > 0) {
            uint256 available = IERC20(params.cashToken).balanceOf(address(this));
            if (available < params.totalCashPool)
                revert InsufficientCashBalance(intent.intentId, params.totalCashPool, available);
        }

        emit MergerInitiated(
            intent.intentId, intent.targetToken,
            params.acquiringToken, params.mergerType
        );

        return abi.encode(uint8(params.mergerType), params.acquiringToken);
    }

    function claimMerger(
        bytes32 intentId,
        uint256 shareBalance,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        MergerState storage state = mergers[intentId];
        if (!state.initialized) revert MergerNotInitialized(intentId);
        if (mergerClaimed[intentId][msg.sender])
            revert AlreadyClaimed(intentId, msg.sender);

        // If election is required, verify the holder elected and deadline has passed
        if (state.params.hasElection) {
            if (mergerElections[intentId][msg.sender] == 0)
                revert ElectionRequired(intentId);
            if (block.timestamp <= state.params.electionDeadline)
                revert ElectionDeadlineNotPassed(intentId);
        }

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender, shareBalance)))
        );
        if (!MerkleProof.verify(merkleProof, state.params.merkleRoot, leaf))
            revert InvalidMerkleProof();

        mergerClaimed[intentId][msg.sender] = true;

        uint256 cashAmount = 0;
        uint256 stockAmount = 0;

        if (state.params.hasElection && state.params.mergerType == MergerType.HYBRID) {
            // Election-based claim: holder chose cash (1) or stock (2)
            uint8 election = mergerElections[intentId][msg.sender];
            if (election == 1) {
                cashAmount = (shareBalance * state.params.cashPerShare) / 1e18;
            } else {
                stockAmount = (shareBalance * state.params.exchangeRatioNum) /
                    state.params.exchangeRatioDen;
            }
        } else if (state.params.mergerType == MergerType.CASH_ONLY) {
            cashAmount = (shareBalance * state.params.cashPerShare) / 1e18;
        } else if (state.params.mergerType == MergerType.STOCK_FOR_STOCK) {
            stockAmount = (shareBalance * state.params.exchangeRatioNum) /
                state.params.exchangeRatioDen;
        } else {
            // HYBRID without election
            cashAmount = (shareBalance * state.params.cashPerShare) / 1e18;
            stockAmount = (shareBalance * state.params.exchangeRatioNum) /
                state.params.exchangeRatioDen;
        }

        // Apply proration factor (BPS, 10000 = 100%)
        if (state.params.prorationFactor < 10000) {
            cashAmount = (cashAmount * state.params.prorationFactor) / 10000;
            stockAmount = (stockAmount * state.params.prorationFactor) / 10000;
        }

        if (cashAmount > 0) {
            IERC20(state.params.cashToken).safeTransfer(msg.sender, cashAmount);
        }
        if (stockAmount > 0) {
            IERC20(state.params.acquiringToken).safeTransfer(msg.sender, stockAmount);
        }

        state.totalCashClaimed += cashAmount;
        state.totalStockClaimed += stockAmount;

        emit MergerClaimed(intentId, msg.sender, cashAmount, stockAmount);
    }

    /// @notice Allows a holder to elect cash (0) or stock (1) for a HYBRID merger with elections.
    /// @param intentId The merger intent ID.
    /// @param option 0 = cash, 1 = stock.
    function electMergerOption(bytes32 intentId, uint8 option) external {
        MergerState storage state = mergers[intentId];
        if (!state.initialized) revert MergerNotInitialized(intentId);
        if (option > 1) revert InvalidElectionOption(option);
        if (block.timestamp > state.params.electionDeadline)
            revert ElectionDeadlinePassed(intentId);

        // Store as 1 = cash, 2 = stock (0 reserved for "no election")
        mergerElections[intentId][msg.sender] = option + 1;

        emit MergerElected(intentId, msg.sender, option);
    }

    /// @notice Marks a merger as completed. Callable by registry after the election deadline.
    /// @param intentId The merger intent ID.
    function finalizeMerger(bytes32 intentId) external {
        require(msg.sender == actionRegistry, "Only registry");
        MergerState storage state = mergers[intentId];
        if (!state.initialized) revert MergerNotInitialized(intentId);
        require(!state.completed, "Already finalized");

        // If there is an election, ensure the deadline has passed before finalizing
        if (state.params.hasElection) {
            if (block.timestamp <= state.params.electionDeadline)
                revert ElectionDeadlineNotPassed(intentId);
        }

        state.completed = true;
        emit MergerFinalized(intentId);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
