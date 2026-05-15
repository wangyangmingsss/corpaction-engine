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

contract DividendDistributor is
    IActionExecutor,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct DividendParams {
        address paymentToken;
        uint256 totalAmount;
        uint256 amountPerShare;
        bytes32 merkleRoot;
        uint256 snapshotBlock;
        uint256 claimDeadline;
        bool    withholding;
        uint256 withholdingBps;
    }

    struct DividendState {
        DividendParams params;
        uint256 totalClaimed;
        bool    initialized;
        bool    fundsReclaimed;
    }

    address public actionRegistry;
    address public treasury;

    mapping(bytes32 => DividendState) public dividends;
    mapping(bytes32 => mapping(address => bool)) public claimed;

    event DividendInitialized(bytes32 indexed intentId, address indexed token,
        uint256 totalAmount, bytes32 merkleRoot, uint256 claimDeadline,
        uint256 snapshotBlock);
    event DividendClaimed(bytes32 indexed intentId, address indexed claimer,
        uint256 amount);
    event DividendWithheld(bytes32 indexed intentId, address indexed holder,
        uint256 grossAmount, uint256 withheld, uint256 netAmount);
    event DividendReclaimed(bytes32 indexed intentId, uint256 amount);

    error AlreadyClaimed(bytes32 intentId, address claimer);
    error ClaimPeriodExpired(bytes32 intentId);
    error ClaimPeriodActive(bytes32 intentId);
    error InvalidMerkleProof();
    error InsufficientFunds(uint256 required, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _registry, address _treasury)
        external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        actionRegistry = _registry;
        treasury = _treasury;
    }

    function execute(
        ICorpActionTypes.ActionIntent calldata intent
    ) external override returns (bytes memory) {
        require(msg.sender == actionRegistry, "Only registry");
        DividendParams memory params = abi.decode(
            intent.actionParams, (DividendParams)
        );

        uint256 balance = IERC20(params.paymentToken).balanceOf(address(this));
        if (balance < params.totalAmount)
            revert InsufficientFunds(params.totalAmount, balance);

        dividends[intent.intentId] = DividendState({
            params: params,
            totalClaimed: 0,
            initialized: true,
            fundsReclaimed: false
        });

        emit DividendInitialized(
            intent.intentId, intent.targetToken,
            params.totalAmount, params.merkleRoot, params.claimDeadline,
            params.snapshotBlock
        );

        return abi.encode(params.totalAmount, params.merkleRoot);
    }

    function claimDividend(
        bytes32 intentId,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        DividendState storage state = dividends[intentId];
        require(state.initialized, "Dividend not initialized");

        if (claimed[intentId][msg.sender])
            revert AlreadyClaimed(intentId, msg.sender);
        if (block.timestamp > state.params.claimDeadline)
            revert ClaimPeriodExpired(intentId);

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender, amount)))
        );
        if (!MerkleProof.verify(merkleProof, state.params.merkleRoot, leaf))
            revert InvalidMerkleProof();

        claimed[intentId][msg.sender] = true;

        if (state.params.withholding && state.params.withholdingBps > 0) {
            uint256 withheld = (amount * state.params.withholdingBps) / 10000;
            uint256 netAmount = amount - withheld;
            // Transfer withheld to treasury
            IERC20(state.params.paymentToken).safeTransfer(treasury, withheld);
            // Transfer net to claimer
            IERC20(state.params.paymentToken).safeTransfer(msg.sender, netAmount);
            emit DividendClaimed(intentId, msg.sender, netAmount);
            emit DividendWithheld(intentId, msg.sender, amount, withheld, netAmount);
            // Track total as full amount for accounting
            state.totalClaimed += amount;
        } else {
            state.totalClaimed += amount;
            IERC20(state.params.paymentToken).safeTransfer(msg.sender, amount);
            emit DividendClaimed(intentId, msg.sender, amount);
        }
    }

    function reclaimExpired(bytes32 intentId) external {
        DividendState storage state = dividends[intentId];
        require(state.initialized, "Not initialized");
        if (block.timestamp <= state.params.claimDeadline)
            revert ClaimPeriodActive(intentId);
        require(!state.fundsReclaimed, "Already reclaimed");

        uint256 remaining = state.params.totalAmount - state.totalClaimed;
        state.fundsReclaimed = true;

        if (remaining > 0) {
            IERC20(state.params.paymentToken).safeTransfer(treasury, remaining);
            emit DividendReclaimed(intentId, remaining);
        }
    }

    function getSnapshotBlock(bytes32 intentId) external view returns (uint256) {
        require(dividends[intentId].initialized, "Dividend not initialized");
        return dividends[intentId].params.snapshotBlock;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
