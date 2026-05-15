// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

contract CorpActionTimelock is
    ICorpActionTypes,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    mapping(ActionType => uint256) public timelocks;

    event TimelockSet(ActionType indexed actionType, uint256 duration);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize() external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
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

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
