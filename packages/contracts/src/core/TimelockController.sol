// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

contract TimelockController is
    ICorpActionTypes,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant SCHEDULER_ROLE = keccak256("SCHEDULER_ROLE");

    mapping(ActionType => uint256) public timelocks;
    mapping(bytes32 => uint256) private _scheduledTimes;

    event TimelockSet(ActionType indexed actionType, uint256 duration);
    event ExecutionScheduled(bytes32 indexed intentId, ActionType indexed actionType, uint256 readyAt);
    event ExecutionCancelled(bytes32 indexed intentId);
    event ExecutionReady(bytes32 indexed intentId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize() external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(SCHEDULER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        // Default timelocks from the spec
        timelocks[ActionType.DIVIDEND] = 1 hours;
        timelocks[ActionType.FORWARD_SPLIT] = 2 hours;
        timelocks[ActionType.REVERSE_SPLIT] = 2 hours;
        timelocks[ActionType.MERGER_CASH] = 24 hours;
        timelocks[ActionType.MERGER_STOCK] = 24 hours;
        timelocks[ActionType.MERGER_HYBRID] = 24 hours;
        timelocks[ActionType.SPINOFF] = 24 hours;
        timelocks[ActionType.DELISTING] = 48 hours;
        timelocks[ActionType.LIQUIDATION] = 48 hours;
        timelocks[ActionType.TICKER_CHANGE] = 1 hours;
    }

    function setTimelock(
        ActionType actionType,
        uint256 duration
    ) external onlyRole(ADMIN_ROLE) {
        timelocks[actionType] = duration;
        emit TimelockSet(actionType, duration);
    }

    function getTimelock(ActionType actionType) external view returns (uint256) {
        return timelocks[actionType];
    }

    function scheduleExecution(
        bytes32 intentId,
        ActionType actionType
    ) external onlyRole(SCHEDULER_ROLE) {
        require(_scheduledTimes[intentId] == 0, "Already scheduled");
        uint256 readyAt = block.timestamp + timelocks[actionType];
        _scheduledTimes[intentId] = readyAt;
        emit ExecutionScheduled(intentId, actionType, readyAt);
    }

    function isReady(bytes32 intentId) external view returns (bool) {
        uint256 scheduled = _scheduledTimes[intentId];
        return scheduled != 0 && block.timestamp >= scheduled;
    }

    function cancelScheduled(bytes32 intentId) external onlyRole(SCHEDULER_ROLE) {
        require(_scheduledTimes[intentId] != 0, "Not scheduled");
        delete _scheduledTimes[intentId];
        emit ExecutionCancelled(intentId);
    }

    function getScheduledTime(bytes32 intentId) external view returns (uint256) {
        return _scheduledTimes[intentId];
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
