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

contract SpinoffExecutor is
    IActionExecutor,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct SpinoffParams {
        address newToken;           // Address of the new spun-off token
        uint256 distributionRatioNum; // e.g., 1 for 1:4 distribution
        uint256 distributionRatioDen; // e.g., 4 for 1:4 distribution
        bytes32 merkleRoot;
        uint256 snapshotBlock;
        uint256 claimDeadline;
    }

    struct SpinoffState {
        SpinoffParams params;
        bool initialized;
        uint256 totalClaimed;
    }

    address public actionRegistry;

    mapping(bytes32 => SpinoffState) public spinoffs;
    mapping(bytes32 => mapping(address => bool)) public spinoffClaimed;

    event SpinoffInitiated(bytes32 indexed intentId, address indexed parentToken,
        address indexed newToken, uint256 ratioNum, uint256 ratioDen);
    event SpinoffClaimed(bytes32 indexed intentId, address indexed claimer,
        uint256 amount);

    error NotInitialized(bytes32 intentId);
    error AlreadyClaimed(bytes32 intentId, address claimer);
    error ClaimExpired(bytes32 intentId);
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

        SpinoffParams memory params = abi.decode(
            intent.actionParams, (SpinoffParams)
        );

        spinoffs[intent.intentId] = SpinoffState({
            params: params,
            initialized: true,
            totalClaimed: 0
        });

        emit SpinoffInitiated(
            intent.intentId, intent.targetToken, params.newToken,
            params.distributionRatioNum, params.distributionRatioDen
        );

        return abi.encode(params.newToken, params.distributionRatioNum, params.distributionRatioDen);
    }

    function claimSpinoff(
        bytes32 intentId,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        SpinoffState storage state = spinoffs[intentId];
        if (!state.initialized) revert NotInitialized(intentId);
        if (spinoffClaimed[intentId][msg.sender])
            revert AlreadyClaimed(intentId, msg.sender);
        if (block.timestamp > state.params.claimDeadline)
            revert ClaimExpired(intentId);

        if (!MerkleDistributor.verifyProof(merkleProof, state.params.merkleRoot, msg.sender, amount))
            revert InvalidMerkleProof();

        spinoffClaimed[intentId][msg.sender] = true;
        state.totalClaimed += amount;

        IERC20(state.params.newToken).safeTransfer(msg.sender, amount);
        emit SpinoffClaimed(intentId, msg.sender, amount);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
