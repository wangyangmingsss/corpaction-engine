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

contract DelistingManager is
    IActionExecutor,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    enum DelistingPhase {
        NONE,
        ANNOUNCED,       // T-48h
        SELL_ONLY,       // T-24h
        PRICE_LOCKED,    // T-0
        LIQUIDATING,     // Distribution phase
        FROZEN           // Terminal
    }

    struct DelistingParams {
        uint256 announcementTime;
        uint256 sellOnlyTime;
        uint256 priceLockTime;
        uint256 finalPrice;      // Price per share in USDC (6 decimals)
        address settlementToken; // USDC
        bytes32 merkleRoot;
        uint256 totalPool;
    }

    struct DelistingState {
        DelistingParams params;
        DelistingPhase phase;
        bool initialized;
        uint256 totalDistributed;
    }

    address public actionRegistry;

    mapping(bytes32 => DelistingState) public delistings;
    mapping(bytes32 => mapping(address => bool)) public delistingClaimed;

    event DelistingAnnounced(bytes32 indexed intentId, address indexed token,
        uint256 finalPrice);
    event DelistingSellOnly(bytes32 indexed intentId, address indexed token);
    event DelistingPriceLocked(bytes32 indexed intentId, uint256 finalPrice);
    event DelistingLiquidated(bytes32 indexed intentId, address indexed claimer,
        uint256 amount);
    event DelistingFrozen(bytes32 indexed intentId, address indexed token);

    error NotInitialized(bytes32 intentId);
    error AlreadyClaimed(bytes32 intentId, address claimer);
    error InvalidPhase(bytes32 intentId, DelistingPhase current, DelistingPhase expected);
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

        DelistingParams memory params = abi.decode(
            intent.actionParams, (DelistingParams)
        );

        delistings[intent.intentId] = DelistingState({
            params: params,
            phase: DelistingPhase.ANNOUNCED,
            initialized: true,
            totalDistributed: 0
        });

        emit DelistingAnnounced(intent.intentId, intent.targetToken, params.finalPrice);

        return abi.encode(uint8(DelistingPhase.ANNOUNCED), params.finalPrice);
    }

    function advancePhase(bytes32 intentId) external {
        DelistingState storage state = delistings[intentId];
        require(state.initialized, "Not initialized");

        if (state.phase == DelistingPhase.ANNOUNCED &&
            block.timestamp >= state.params.sellOnlyTime) {
            state.phase = DelistingPhase.SELL_ONLY;
            emit DelistingSellOnly(intentId, address(0));
        } else if (state.phase == DelistingPhase.SELL_ONLY &&
            block.timestamp >= state.params.priceLockTime) {
            state.phase = DelistingPhase.PRICE_LOCKED;
            emit DelistingPriceLocked(intentId, state.params.finalPrice);
            state.phase = DelistingPhase.LIQUIDATING;
        }
    }

    function claimLiquidation(
        bytes32 intentId,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        DelistingState storage state = delistings[intentId];
        if (!state.initialized) revert NotInitialized(intentId);
        if (state.phase != DelistingPhase.LIQUIDATING)
            revert InvalidPhase(intentId, state.phase, DelistingPhase.LIQUIDATING);
        if (delistingClaimed[intentId][msg.sender])
            revert AlreadyClaimed(intentId, msg.sender);

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(msg.sender, amount)))
        );
        if (!MerkleProof.verify(merkleProof, state.params.merkleRoot, leaf))
            revert InvalidMerkleProof();

        delistingClaimed[intentId][msg.sender] = true;
        state.totalDistributed += amount;

        IERC20(state.params.settlementToken).safeTransfer(msg.sender, amount);
        emit DelistingLiquidated(intentId, msg.sender, amount);
    }

    function freezeToken(bytes32 intentId) external {
        DelistingState storage state = delistings[intentId];
        require(state.initialized, "Not initialized");
        require(state.phase == DelistingPhase.LIQUIDATING, "Not in liquidation phase");
        state.phase = DelistingPhase.FROZEN;
        emit DelistingFrozen(intentId, address(0));
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
