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

    event MergerInitiated(bytes32 indexed intentId, address indexed sourceToken,
        address indexed acquiringToken, MergerType mergerType);
    event MergerClaimed(bytes32 indexed intentId, address indexed claimer,
        uint256 cashAmount, uint256 stockAmount);

    error MergerNotInitialized(bytes32 intentId);
    error AlreadyClaimed(bytes32 intentId, address claimer);
    error InvalidMerkleProof();

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

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender, shareBalance)))
        );
        if (!MerkleProof.verify(merkleProof, state.params.merkleRoot, leaf))
            revert InvalidMerkleProof();

        mergerClaimed[intentId][msg.sender] = true;

        uint256 cashAmount = 0;
        uint256 stockAmount = 0;

        if (state.params.mergerType == MergerType.CASH_ONLY) {
            cashAmount = (shareBalance * state.params.cashPerShare) / 1e18;
            IERC20(state.params.cashToken).safeTransfer(msg.sender, cashAmount);
        } else if (state.params.mergerType == MergerType.STOCK_FOR_STOCK) {
            stockAmount = (shareBalance * state.params.exchangeRatioNum) /
                state.params.exchangeRatioDen;
            IERC20(state.params.acquiringToken).safeTransfer(msg.sender, stockAmount);
        } else {
            // HYBRID
            cashAmount = (shareBalance * state.params.cashPerShare) / 1e18;
            stockAmount = (shareBalance * state.params.exchangeRatioNum) /
                state.params.exchangeRatioDen;
            IERC20(state.params.cashToken).safeTransfer(msg.sender, cashAmount);
            IERC20(state.params.acquiringToken).safeTransfer(msg.sender, stockAmount);
        }

        state.totalCashClaimed += cashAmount;
        state.totalStockClaimed += stockAmount;

        emit MergerClaimed(intentId, msg.sender, cashAmount, stockAmount);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
