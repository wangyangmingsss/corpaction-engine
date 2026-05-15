// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SplitExecutor} from "../../src/executors/SplitExecutor.sol";
import {MockERC8056} from "../mocks/MockERC8056.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title NVDA 10:1 Forward Split Replay
/// @notice Simulates Nvidia's July 2024 10-for-1 stock split
contract NVDA_SplitTest is Test {
    SplitExecutor public executor;
    MockERC8056 public nvdaToken;

    address public registry = address(this);

    address public retailInvestor = makeAddr("retailInvestor");
    address public hedgeFund = makeAddr("hedgeFund");
    address public pensionFund = makeAddr("pensionFund");

    function setUp() public {
        nvdaToken = new MockERC8056("NVIDIA Corporation", "NVDA", 18);

        SplitExecutor impl = new SplitExecutor();
        bytes memory initData = abi.encodeWithSelector(
            SplitExecutor.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        executor = SplitExecutor(address(proxy));

        // Pre-split holdings (raw shares)
        nvdaToken.mint(retailInvestor, 10e18);     // 10 shares
        nvdaToken.mint(hedgeFund, 5_000e18);       // 5,000 shares
        nvdaToken.mint(pensionFund, 50_000e18);    // 50,000 shares
    }

    function test_nvda10to1ForwardSplit() public {
        // Verify pre-split state
        assertEq(nvdaToken.uiMultiplier(), 1e18);
        assertEq(nvdaToken.balanceOfUI(retailInvestor), 10e18);

        // Execute 10:1 forward split
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 10,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 10e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: keccak256("nvda-10to1-split-2024"),
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(nvdaToken),
            ticker: "NVDA",
            isin: "US67066G1040",
            recordDate: 1718409600, // June 7, 2024
            exDate: 1720224000,     // June 10, 2024
            effectiveDate: 1720224000,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("sec-edgar-nvda-8k-split"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        bytes memory result = executor.execute(intent);
        (uint256 oldMul, uint256 newMul) = abi.decode(result, (uint256, uint256));

        assertEq(oldMul, 1e18);
        assertEq(newMul, 10e18);

        // Verify post-split UI balances: 10x the pre-split values
        assertEq(nvdaToken.balanceOfUI(retailInvestor), 100e18);     // 10 -> 100
        assertEq(nvdaToken.balanceOfUI(hedgeFund), 50_000e18);      // 5k -> 50k
        assertEq(nvdaToken.balanceOfUI(pensionFund), 500_000e18);   // 50k -> 500k

        // Raw balances unchanged
        assertEq(nvdaToken.balanceOf(retailInvestor), 10e18);
        assertEq(nvdaToken.balanceOf(hedgeFund), 5_000e18);
        assertEq(nvdaToken.balanceOf(pensionFund), 50_000e18);

        // Multiplier set correctly
        assertEq(nvdaToken.uiMultiplier(), 10e18);
    }

    function test_nvdaSplit_subsequentSplit() public {
        // First split: 10:1
        SplitExecutor.SplitParams memory params1 = SplitExecutor.SplitParams({
            numerator: 10,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 10e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent1 = ICorpActionTypes.ActionIntent({
            intentId: keccak256("nvda-split-1"),
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(nvdaToken),
            ticker: "NVDA",
            isin: "US67066G1040",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params1),
            sourceAttestation: keccak256("test1"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        executor.execute(intent1);
        assertEq(nvdaToken.uiMultiplier(), 10e18);

        // Second split: 2:1 on top of the first
        SplitExecutor.SplitParams memory params2 = SplitExecutor.SplitParams({
            numerator: 2,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 20e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent2 = ICorpActionTypes.ActionIntent({
            intentId: keccak256("nvda-split-2"),
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(nvdaToken),
            ticker: "NVDA",
            isin: "US67066G1040",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params2),
            sourceAttestation: keccak256("test2"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        executor.execute(intent2);

        // 10x * 2x = 20x
        assertEq(nvdaToken.uiMultiplier(), 20e18);
        assertEq(nvdaToken.balanceOfUI(retailInvestor), 200e18); // 10 * 20
    }
}
