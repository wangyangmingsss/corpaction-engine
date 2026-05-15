// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionExecutor} from "../interfaces/IActionExecutor.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";
import {IERC8056} from "../interfaces/IERC8056.sol";
import {MultiplierMath} from "../libraries/MultiplierMath.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract SplitExecutor is IActionExecutor, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct SplitParams {
        uint256 numerator;
        uint256 denominator;
        bool    isReverse;
        uint256 expectedNewMultiplier;
        uint256 fractionalHandling; // 0=round down, 1=round up, 2=cash-in-lieu
        address cashInLieuToken;
        uint256 cashInLieuPrice;
    }

    struct CashInLieuState {
        address cashToken;
        uint256 pricePerShare;
        bytes32 merkleRoot;
        uint256 claimDeadline;
        bool initialized;
    }

    address public actionRegistry;

    mapping(bytes32 => CashInLieuState) public cashInLieu;
    mapping(bytes32 => mapping(address => bool)) public cashInLieuClaimed;

    event SplitExecuted(bytes32 indexed intentId, address indexed token,
        uint256 oldMultiplier, uint256 newMultiplier,
        uint256 numerator, uint256 denominator, bool isReverse);
    event CashInLieuInitialized(bytes32 indexed intentId, address cashToken, uint256 pricePerShare);
    event CashInLieuClaimed(bytes32 indexed intentId, address indexed holder, uint256 fractionalAmount, uint256 payout);

    error MultiplierMismatch(uint256 expected, uint256 calculated);
    error InvalidSplitRatio(uint256 num, uint256 den);
    error NotERC8056Compliant(address token);
    error CashInLieuNotInitialized(bytes32 intentId);
    error CashInLieuAlreadyClaimed(bytes32 intentId, address holder);
    error CashInLieuMerkleNotSet(bytes32 intentId);
    error CashInLieuDeadlinePassed(bytes32 intentId);
    error CashInLieuInvalidProof();
    error InvalidCashInLieuParams();

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

        SplitParams memory params = abi.decode(
            intent.actionParams, (SplitParams)
        );
        if (params.numerator == 0 || params.denominator == 0)
            revert InvalidSplitRatio(params.numerator, params.denominator);

        IERC8056 token = IERC8056(intent.targetToken);

        // Verify ERC-8056 compliance
        try token.uiMultiplier() returns (uint256) {} catch {
            revert NotERC8056Compliant(intent.targetToken);
        }

        uint256 oldMultiplier = token.uiMultiplier();
        uint256 newMultiplier;

        if (params.isReverse) {
            newMultiplier = MultiplierMath.divMultiplier(
                oldMultiplier, params.numerator, params.denominator
            );
        } else {
            newMultiplier = MultiplierMath.mulMultiplier(
                oldMultiplier, params.numerator, params.denominator
            );
        }

        // Safety check: verify against pre-calculated value
        if (newMultiplier != params.expectedNewMultiplier)
            revert MultiplierMismatch(
                params.expectedNewMultiplier, newMultiplier
            );

        // Execute the split
        token.setUIMultiplier(newMultiplier);

        // Store cash-in-lieu parameters for reverse splits with fractional handling
        if (params.isReverse && params.fractionalHandling == 2) {
            if (params.cashInLieuToken == address(0) || params.cashInLieuPrice == 0)
                revert InvalidCashInLieuParams();

            cashInLieu[intent.intentId] = CashInLieuState({
                cashToken: params.cashInLieuToken,
                pricePerShare: params.cashInLieuPrice,
                merkleRoot: bytes32(0),
                claimDeadline: 0,
                initialized: true
            });

            emit CashInLieuInitialized(
                intent.intentId, params.cashInLieuToken, params.cashInLieuPrice
            );
        }

        emit SplitExecuted(
            intent.intentId, intent.targetToken,
            oldMultiplier, newMultiplier,
            params.numerator, params.denominator, params.isReverse
        );

        return abi.encode(oldMultiplier, newMultiplier);
    }

    function setCashInLieuMerkle(
        bytes32 intentId,
        bytes32 merkleRoot,
        uint256 claimDeadline
    ) external {
        require(msg.sender == actionRegistry, "Only registry");
        if (!cashInLieu[intentId].initialized)
            revert CashInLieuNotInitialized(intentId);

        cashInLieu[intentId].merkleRoot = merkleRoot;
        cashInLieu[intentId].claimDeadline = claimDeadline;
    }

    function claimCashInLieu(
        bytes32 intentId,
        uint256 fractionalAmount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        CashInLieuState storage state = cashInLieu[intentId];

        if (!state.initialized)
            revert CashInLieuNotInitialized(intentId);
        if (state.merkleRoot == bytes32(0))
            revert CashInLieuMerkleNotSet(intentId);
        if (block.timestamp > state.claimDeadline)
            revert CashInLieuDeadlinePassed(intentId);
        if (cashInLieuClaimed[intentId][msg.sender])
            revert CashInLieuAlreadyClaimed(intentId, msg.sender);

        // Verify Merkle proof: leaf = keccak256(abi.encodePacked(holder, fractionalAmount))
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, fractionalAmount));
        if (!MerkleProof.verify(merkleProof, state.merkleRoot, leaf))
            revert CashInLieuInvalidProof();

        cashInLieuClaimed[intentId][msg.sender] = true;

        uint256 payout = fractionalAmount * state.pricePerShare / 1e18;
        IERC20(state.cashToken).safeTransfer(msg.sender, payout);

        emit CashInLieuClaimed(intentId, msg.sender, fractionalAmount, payout);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
