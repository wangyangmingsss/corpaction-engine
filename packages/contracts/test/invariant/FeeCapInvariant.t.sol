// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../../src/fees/FeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FeeCapInvariantHandler is Test {
    FeeCollector public collector;

    constructor(FeeCollector _collector) {
        collector = _collector;
    }

    function calculateFee(uint8 actionTypeRaw, uint256 holderCount) external view {
        actionTypeRaw = uint8(bound(actionTypeRaw, 0, 9));
        holderCount = bound(holderCount, 0, 100_000_000);
        ICorpActionTypes.ActionType actionType = ICorpActionTypes.ActionType(actionTypeRaw);

        uint256 fee = collector.calculateFee(actionType, holderCount);
        (,,uint256 cap) = collector.feeSchedules(actionType);

        assert(fee <= cap || cap == 0);
    }
}

contract FeeCapInvariantTest is Test {
    FeeCollector public collector;
    FeeCapInvariantHandler public handler;
    MockERC20 public usdc;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        FeeCollector impl = new FeeCollector();
        bytes memory initData = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            address(usdc),
            makeAddr("treasury")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        collector = FeeCollector(address(proxy));

        handler = new FeeCapInvariantHandler(collector);
        targetContract(address(handler));
    }

    /// @dev Invariant: fees never exceed the configured cap for any action type
    function invariant_feesNeverExceedCap() public view {
        for (uint8 i = 0; i < 10; i++) {
            ICorpActionTypes.ActionType actionType = ICorpActionTypes.ActionType(i);
            uint256 fee = collector.calculateFee(actionType, 10_000_000);
            (,,uint256 cap) = collector.feeSchedules(actionType);
            assertLe(fee, cap);
        }
    }
}
