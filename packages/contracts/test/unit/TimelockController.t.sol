// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TimelockController} from "../../src/core/TimelockController.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TimelockControllerTest is Test {
    TimelockController public controller;

    address public admin = address(this);
    address public nonAdmin = makeAddr("nonAdmin");

    function setUp() public {
        TimelockController impl = new TimelockController();
        bytes memory initData = abi.encodeWithSelector(
            TimelockController.initialize.selector
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        controller = TimelockController(address(proxy));
    }

    // ── Default durations ──────────────────────────────────────────────

    function test_defaultTimelock_dividend() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.DIVIDEND),
            1 hours
        );
    }

    function test_defaultTimelock_forwardSplit() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.FORWARD_SPLIT),
            2 hours
        );
    }

    function test_defaultTimelock_reverseSplit() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.REVERSE_SPLIT),
            2 hours
        );
    }

    function test_defaultTimelock_mergerCash() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.MERGER_CASH),
            24 hours
        );
    }

    function test_defaultTimelock_mergerStock() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.MERGER_STOCK),
            24 hours
        );
    }

    function test_defaultTimelock_mergerHybrid() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.MERGER_HYBRID),
            24 hours
        );
    }

    function test_defaultTimelock_spinoff() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.SPINOFF),
            24 hours
        );
    }

    function test_defaultTimelock_delisting() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.DELISTING),
            48 hours
        );
    }

    function test_defaultTimelock_liquidation() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.LIQUIDATION),
            48 hours
        );
    }

    function test_defaultTimelock_tickerChange() public view {
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.TICKER_CHANGE),
            1 hours
        );
    }

    // ── setTimelock ────────────────────────────────────────────────────

    function test_setTimelock_updatesValue() public {
        controller.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 5 hours);
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.DIVIDEND),
            5 hours
        );
    }

    function test_setTimelock_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TimelockController.TimelockSet(
            ICorpActionTypes.ActionType.SPINOFF, 12 hours
        );
        controller.setTimelock(ICorpActionTypes.ActionType.SPINOFF, 12 hours);
    }

    function test_setTimelock_toZero() public {
        controller.setTimelock(ICorpActionTypes.ActionType.DELISTING, 0);
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.DELISTING),
            0
        );
    }

    function test_setTimelock_overwritesPrevious() public {
        controller.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 10 hours);
        controller.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 3 hours);
        assertEq(
            controller.getTimelock(ICorpActionTypes.ActionType.DIVIDEND),
            3 hours
        );
    }

    // ── Access control ─────────────────────────────────────────────────

    function test_revert_setTimelock_nonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        controller.setTimelock(ICorpActionTypes.ActionType.DIVIDEND, 999);
    }

    function test_getTimelock_publiclyReadable() public view {
        // Any address can read; just verify no revert.
        uint256 val = controller.getTimelock(ICorpActionTypes.ActionType.DIVIDEND);
        assertGt(val, 0);
    }

    // ── Mapping storage via public accessor ────────────────────────────

    function test_timelocks_mappingAccessor() public view {
        // The public `timelocks` mapping should match getTimelock.
        assertEq(
            controller.timelocks(ICorpActionTypes.ActionType.MERGER_CASH),
            controller.getTimelock(ICorpActionTypes.ActionType.MERGER_CASH)
        );
    }
}
