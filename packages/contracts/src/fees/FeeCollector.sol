// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

contract FeeCollector is
    ICorpActionTypes,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct FeeSchedule {
        uint256 baseFee;        // Base fee in USDC (6 decimals)
        uint256 perHolderFee;   // Per-holder fee in USDC (6 decimals)
        uint256 capPerAction;   // Maximum fee per action
    }

    IERC20 public feeToken;     // USDC
    address public treasury;

    mapping(ActionType => FeeSchedule) public feeSchedules;
    uint256 public totalFeesCollected;

    event FeeCollected(bytes32 indexed intentId, ActionType indexed actionType,
        uint256 feeAmount);
    event FeeScheduleUpdated(ActionType indexed actionType, uint256 baseFee,
        uint256 perHolderFee, uint256 cap);
    event TreasuryUpdated(address newTreasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address _feeToken,
        address _treasury
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        feeToken = IERC20(_feeToken);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FEE_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        // Default fee schedules (amounts in USDC with 6 decimals)
        feeSchedules[ActionType.DIVIDEND] = FeeSchedule(100e6, 0.01e6, 10_000e6);
        feeSchedules[ActionType.FORWARD_SPLIT] = FeeSchedule(50e6, 0, 50e6);
        feeSchedules[ActionType.REVERSE_SPLIT] = FeeSchedule(100e6, 0.005e6, 5_000e6);
        feeSchedules[ActionType.MERGER_CASH] = FeeSchedule(500e6, 0.02e6, 50_000e6);
        feeSchedules[ActionType.MERGER_STOCK] = FeeSchedule(1_000e6, 0.05e6, 100_000e6);
        feeSchedules[ActionType.MERGER_HYBRID] = FeeSchedule(1_000e6, 0.05e6, 100_000e6);
        feeSchedules[ActionType.SPINOFF] = FeeSchedule(500e6, 0.02e6, 50_000e6);
        feeSchedules[ActionType.DELISTING] = FeeSchedule(200e6, 0.01e6, 20_000e6);
        feeSchedules[ActionType.LIQUIDATION] = FeeSchedule(200e6, 0.01e6, 20_000e6);
        feeSchedules[ActionType.TICKER_CHANGE] = FeeSchedule(100e6, 0.01e6, 5_000e6);
    }

    function calculateFee(
        ActionType actionType,
        uint256 holderCount
    ) public view returns (uint256) {
        FeeSchedule memory schedule = feeSchedules[actionType];
        uint256 fee = schedule.baseFee + (schedule.perHolderFee * holderCount);
        if (fee > schedule.capPerAction) {
            fee = schedule.capPerAction;
        }
        return fee;
    }

    function collectFee(
        bytes32 intentId,
        ActionType actionType,
        uint256 holderCount,
        address payer
    ) external returns (uint256 feeAmount) {
        feeAmount = calculateFee(actionType, holderCount);
        if (feeAmount > 0) {
            feeToken.safeTransferFrom(payer, treasury, feeAmount);
            totalFeesCollected += feeAmount;
            emit FeeCollected(intentId, actionType, feeAmount);
        }
    }

    function setFeeSchedule(
        ActionType actionType,
        uint256 baseFee,
        uint256 perHolderFee,
        uint256 cap
    ) external onlyRole(FEE_ADMIN_ROLE) {
        feeSchedules[actionType] = FeeSchedule(baseFee, perHolderFee, cap);
        emit FeeScheduleUpdated(actionType, baseFee, perHolderFee, cap);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
