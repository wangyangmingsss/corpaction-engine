// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../../src/fees/FeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FeeCollectorTest is Test {
    FeeCollector public collector;
    MockERC20 public usdc;

    address public treasury = makeAddr("treasury");
    address public payer = makeAddr("payer");
    address public nonAdmin = makeAddr("nonAdmin");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        FeeCollector impl = new FeeCollector();
        bytes memory initData = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            address(usdc),
            treasury
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        collector = FeeCollector(address(proxy));

        // Fund payer and approve
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(collector), type(uint256).max);
    }

    function test_calculateFee_dividend() public view {
        // DIVIDEND: base=100e6, perHolder=0.01e6, cap=10_000e6
        uint256 fee = collector.calculateFee(ICorpActionTypes.ActionType.DIVIDEND, 1000);
        // 100e6 + 1000 * 0.01e6 = 100e6 + 10e6 = 110e6
        assertEq(fee, 110e6);
    }

    function test_calculateFee_forwardSplit() public view {
        // FORWARD_SPLIT: base=50e6, perHolder=0, cap=50e6
        uint256 fee = collector.calculateFee(ICorpActionTypes.ActionType.FORWARD_SPLIT, 5000);
        assertEq(fee, 50e6); // base only, no per-holder
    }

    function test_calculateFee_mergerStock() public view {
        // MERGER_STOCK: base=1_000e6, perHolder=0.05e6, cap=100_000e6
        uint256 fee = collector.calculateFee(ICorpActionTypes.ActionType.MERGER_STOCK, 100);
        // 1000e6 + 100 * 0.05e6 = 1000e6 + 5e6 = 1005e6
        assertEq(fee, 1005e6);
    }

    function test_capEnforcement() public view {
        // DIVIDEND: cap=10_000e6. With huge holder count, should cap.
        uint256 fee = collector.calculateFee(
            ICorpActionTypes.ActionType.DIVIDEND, 10_000_000
        );
        assertEq(fee, 10_000e6);
    }

    function test_collectFee() public {
        bytes32 intentId = keccak256("fee-test");
        uint256 fee = collector.collectFee(
            intentId,
            ICorpActionTypes.ActionType.DIVIDEND,
            1000,
            payer
        );

        assertEq(fee, 110e6);
        assertEq(usdc.balanceOf(treasury), 110e6);
        assertEq(collector.totalFeesCollected(), 110e6);
    }

    function test_treasuryUpdate() public {
        address newTreasury = makeAddr("newTreasury");
        collector.setTreasury(newTreasury);
        assertEq(collector.treasury(), newTreasury);
    }

    function test_scheduleUpdate() public {
        collector.setFeeSchedule(
            ICorpActionTypes.ActionType.DIVIDEND,
            200e6,  // new baseFee
            0.02e6, // new perHolder
            20_000e6 // new cap
        );

        uint256 fee = collector.calculateFee(ICorpActionTypes.ActionType.DIVIDEND, 1000);
        // 200e6 + 1000 * 0.02e6 = 200e6 + 20e6 = 220e6
        assertEq(fee, 220e6);
    }

    function test_revert_unauthorizedScheduleUpdate() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        collector.setFeeSchedule(
            ICorpActionTypes.ActionType.DIVIDEND, 0, 0, 0
        );
    }

    function test_revert_unauthorizedTreasuryUpdate() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        collector.setTreasury(makeAddr("hacker"));
    }

    function test_calculateFee_allActionTypes() public view {
        // Verify all action types return non-zero base fees
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.DIVIDEND, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.FORWARD_SPLIT, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.REVERSE_SPLIT, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.MERGER_CASH, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.MERGER_STOCK, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.MERGER_HYBRID, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.SPINOFF, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.DELISTING, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.LIQUIDATION, 0), 0);
        assertGt(collector.calculateFee(ICorpActionTypes.ActionType.TICKER_CHANGE, 0), 0);
    }
}
