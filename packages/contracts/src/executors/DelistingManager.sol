// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleDistributor} from "../libraries/MerkleDistributor.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IActionExecutor} from "../interfaces/IActionExecutor.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";
import {ChainlinkPriceAdapter} from "../integrations/ChainlinkPriceAdapter.sol";

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
        uint256 claimDeadline;   // Deadline after which claims are rejected
    }

    struct DelistingState {
        DelistingParams params;
        DelistingPhase phase;
        bool initialized;
        uint256 totalDistributed;
        address targetToken;     // Actual token being delisted
        bool disputed;           // Whether the delisting is under dispute
        string disputeReason;    // Reason for the dispute
    }

    address public actionRegistry;
    ChainlinkPriceAdapter public priceAdapter;

    mapping(bytes32 => DelistingState) public delistings;
    mapping(bytes32 => mapping(address => bool)) public delistingClaimed;
    mapping(bytes32 => string) public delistingTickers;
    mapping(bytes32 => string) public delistingPriceSources;
    mapping(bytes32 => uint256) public delistingPriceTimestamps;

    event DelistingAnnounced(bytes32 indexed intentId, address indexed token,
        uint256 finalPrice);
    event DelistingSellOnly(bytes32 indexed intentId, address indexed token);
    event DelistingPriceLocked(bytes32 indexed intentId, uint256 finalPrice);
    event DelistingLiquidated(bytes32 indexed intentId, address indexed claimer,
        uint256 amount);
    event DelistingFrozen(bytes32 indexed intentId, address indexed token);
    event DelistingDisputed(bytes32 indexed intentId, address indexed validator,
        string reason);
    event DelistingRolledBack(bytes32 indexed intentId, address indexed validator);
    event FinalPriceLocked(bytes32 indexed intentId, uint256 finalPrice, string source, uint256 sourceTimestamp);

    error NotInitialized(bytes32 intentId);
    error AlreadyClaimed(bytes32 intentId, address claimer);
    error InvalidPhase(bytes32 intentId, DelistingPhase current, DelistingPhase expected);
    error InvalidMerkleProof();
    error ClaimDeadlineExpired(bytes32 intentId);
    error DelistingIsDisputed(bytes32 intentId);
    error DelistingNotDisputed(bytes32 intentId);
    error PriceAlreadyLocked(bytes32 intentId);
    error InvalidPriceAdapterAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _registry, address _priceAdapter) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        actionRegistry = _registry;
        if (_priceAdapter == address(0)) revert InvalidPriceAdapterAddress();
        priceAdapter = ChainlinkPriceAdapter(_priceAdapter);
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
            totalDistributed: 0,
            targetToken: intent.targetToken,
            disputed: false,
            disputeReason: ""
        });

        delistingTickers[intent.intentId] = intent.ticker;

        emit DelistingAnnounced(intent.intentId, intent.targetToken, params.finalPrice);

        return abi.encode(uint8(DelistingPhase.ANNOUNCED), params.finalPrice);
    }

    function advancePhase(bytes32 intentId) external {
        DelistingState storage state = delistings[intentId];
        require(state.initialized, "Not initialized");
        if (state.disputed) revert DelistingIsDisputed(intentId);

        if (state.phase == DelistingPhase.ANNOUNCED &&
            block.timestamp >= state.params.sellOnlyTime) {
            state.phase = DelistingPhase.SELL_ONLY;
            emit DelistingSellOnly(intentId, state.targetToken);
        } else if (state.phase == DelistingPhase.SELL_ONLY &&
            block.timestamp >= state.params.priceLockTime) {
            state.phase = DelistingPhase.PRICE_LOCKED;
            emit DelistingPriceLocked(intentId, state.params.finalPrice);
        } else if (state.phase == DelistingPhase.PRICE_LOCKED) {
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
        if (state.params.claimDeadline != 0 && block.timestamp > state.params.claimDeadline)
            revert ClaimDeadlineExpired(intentId);
        if (state.disputed) revert DelistingIsDisputed(intentId);

        if (!MerkleDistributor.verifyProof(merkleProof, state.params.merkleRoot, msg.sender, amount))
            revert InvalidMerkleProof();

        delistingClaimed[intentId][msg.sender] = true;
        state.totalDistributed += amount;

        IERC20(state.params.settlementToken).safeTransfer(msg.sender, amount);
        emit DelistingLiquidated(intentId, msg.sender, amount);
    }

    /// @notice Lock the final price by auto-fetching from Chainlink price feed
    /// @param intentId The delisting intent identifier
    function lockFinalPrice(bytes32 intentId) external {
        DelistingState storage state = delistings[intentId];
        if (!state.initialized) revert NotInitialized(intentId);
        if (state.disputed) revert DelistingIsDisputed(intentId);

        // Only allow during SELL_ONLY or PRICE_LOCKED phase
        if (state.phase != DelistingPhase.SELL_ONLY && state.phase != DelistingPhase.PRICE_LOCKED) {
            revert InvalidPhase(intentId, state.phase, DelistingPhase.SELL_ONLY);
        }

        bytes32 tickerHash = keccak256(abi.encodePacked(delistingTickers[intentId]));
        (uint256 chainlinkPrice, uint256 updatedAt) = priceAdapter.getLatestPrice(tickerHash);

        // Convert Chainlink 8-decimal price to USDC 6-decimal
        uint256 usdcPrice = chainlinkPrice / 100;

        state.params.finalPrice = usdcPrice;
        delistingPriceSources[intentId] = "chainlink";
        delistingPriceTimestamps[intentId] = updatedAt;

        emit FinalPriceLocked(intentId, usdcPrice, "chainlink", updatedAt);
    }

    /// @notice Manually lock the final price as a fallback when Chainlink is unavailable
    /// @param intentId The delisting intent identifier
    /// @param _finalPrice The final price in USDC (6 decimals)
    function lockFinalPriceManual(bytes32 intentId, uint256 _finalPrice) external {
        DelistingState storage state = delistings[intentId];
        if (!state.initialized) revert NotInitialized(intentId);
        if (state.disputed) revert DelistingIsDisputed(intentId);

        // Only allow during SELL_ONLY or PRICE_LOCKED phase
        if (state.phase != DelistingPhase.SELL_ONLY && state.phase != DelistingPhase.PRICE_LOCKED) {
            revert InvalidPhase(intentId, state.phase, DelistingPhase.SELL_ONLY);
        }

        require(_finalPrice > 0, "Price must be positive");

        state.params.finalPrice = _finalPrice;
        delistingPriceSources[intentId] = "manual";
        delistingPriceTimestamps[intentId] = block.timestamp;

        emit FinalPriceLocked(intentId, _finalPrice, "manual", block.timestamp);
    }

    function freezeToken(bytes32 intentId) external {
        DelistingState storage state = delistings[intentId];
        require(state.initialized, "Not initialized");
        require(state.phase == DelistingPhase.LIQUIDATING, "Not in liquidation phase");
        state.phase = DelistingPhase.FROZEN;
        emit DelistingFrozen(intentId, state.targetToken);
    }

    function disputeDelisting(bytes32 intentId, string calldata reason) external {
        DelistingState storage state = delistings[intentId];
        require(state.initialized, "Not initialized");
        require(state.phase != DelistingPhase.FROZEN, "Already frozen");
        require(!state.disputed, "Already disputed");
        require(bytes(reason).length > 0, "Reason required");

        state.disputed = true;
        state.disputeReason = reason;

        emit DelistingDisputed(intentId, msg.sender, reason);
    }

    function rollbackDelisting(bytes32 intentId) external {
        DelistingState storage state = delistings[intentId];
        require(state.initialized, "Not initialized");
        if (!state.disputed) revert DelistingNotDisputed(intentId);
        require(state.phase != DelistingPhase.FROZEN, "Already frozen");

        state.phase = DelistingPhase.NONE;
        state.initialized = false;
        state.disputed = false;
        state.disputeReason = "";

        emit DelistingRolledBack(intentId, msg.sender);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
