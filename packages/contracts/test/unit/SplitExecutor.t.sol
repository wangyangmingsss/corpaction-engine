// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SplitExecutor} from "../../src/executors/SplitExecutor.sol";
import {MockERC8056} from "../mocks/MockERC8056.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SplitExecutorTest is Test {
    SplitExecutor public executor;
    MockERC8056 public stockToken;
    MockERC20 public usdc;
    MockERC20 public plainToken;

    address public registry = address(this); // test contract acts as registry
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        stockToken = new MockERC8056("NVDA Token", "NVDA", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        plainToken = new MockERC20("Plain", "PLN", 18);

        SplitExecutor impl = new SplitExecutor();
        bytes memory initData = abi.encodeWithSelector(
            SplitExecutor.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        executor = SplitExecutor(address(proxy));

        stockToken.mint(alice, 100e18);
        stockToken.mint(bob, 250e18);
    }

    function _buildSplitIntent(
        bytes32 intentId,
        SplitExecutor.SplitParams memory params
    ) internal view returns (ICorpActionTypes.ActionIntent memory) {
        return ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(stockToken),
            ticker: "NVDA",
            isin: "US67066G1040",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });
    }

    function test_forwardSplit_4to1() public {
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 4,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 4e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent = _buildSplitIntent(
            keccak256("split-4to1"), params
        );

        bytes memory result = executor.execute(intent);
        (uint256 oldMul, uint256 newMul) = abi.decode(result, (uint256, uint256));

        assertEq(oldMul, 1e18);
        assertEq(newMul, 4e18);
        assertEq(stockToken.uiMultiplier(), 4e18);
        assertEq(stockToken.balanceOfUI(alice), 400e18);
        assertEq(stockToken.balanceOfUI(bob), 1000e18);
    }

    function test_reverseSplit_1to10() public {
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 10,
            denominator: 1,
            isReverse: true,
            expectedNewMultiplier: 0.1e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent = _buildSplitIntent(
            keccak256("split-reverse"), params
        );

        bytes memory result = executor.execute(intent);
        (uint256 oldMul, uint256 newMul) = abi.decode(result, (uint256, uint256));

        assertEq(oldMul, 1e18);
        assertEq(newMul, 0.1e18);
        assertEq(stockToken.uiMultiplier(), 0.1e18);
        assertEq(stockToken.balanceOfUI(alice), 10e18);
    }

    function test_cashInLieu_initialization() public {
        bytes32 intentId = keccak256("split-cil");

        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 10,
            denominator: 1,
            isReverse: true,
            expectedNewMultiplier: 0.1e18,
            fractionalHandling: 2,
            cashInLieuToken: address(usdc),
            cashInLieuPrice: 50e6
        });

        ICorpActionTypes.ActionIntent memory intent = _buildSplitIntent(intentId, params);
        executor.execute(intent);

        (address cashToken, uint256 price,, , bool initialized) =
            executor.cashInLieu(intentId);

        assertTrue(initialized);
        assertEq(cashToken, address(usdc));
        assertEq(price, 50e6);
    }

    function test_revert_multiplierMismatch() public {
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 4,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 999e18, // wrong value
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent = _buildSplitIntent(
            keccak256("bad-split"), params
        );

        vm.expectRevert(abi.encodeWithSelector(
            SplitExecutor.MultiplierMismatch.selector, 999e18, 4e18
        ));
        executor.execute(intent);
    }

    function test_revert_notERC8056Compliant() public {
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 4,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 4e18,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: keccak256("bad-token"),
            actionType: ICorpActionTypes.ActionType.FORWARD_SPLIT,
            targetToken: address(plainToken), // not ERC8056
            ticker: "PLN",
            isin: "XX",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        vm.expectRevert(abi.encodeWithSelector(
            SplitExecutor.NotERC8056Compliant.selector, address(plainToken)
        ));
        executor.execute(intent);
    }

    function test_revert_invalidSplitRatio() public {
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 0,
            denominator: 1,
            isReverse: false,
            expectedNewMultiplier: 0,
            fractionalHandling: 0,
            cashInLieuToken: address(0),
            cashInLieuPrice: 0
        });

        ICorpActionTypes.ActionIntent memory intent = _buildSplitIntent(
            keccak256("zero-split"), params
        );

        vm.expectRevert(abi.encodeWithSelector(
            SplitExecutor.InvalidSplitRatio.selector, 0, 1
        ));
        executor.execute(intent);
    }

    function test_claimCashInLieu() public {
        bytes32 intentId = keccak256("split-cil-claim");
        uint256 fractionalAmount = 0.5e18;

        // Execute reverse split with cash-in-lieu
        SplitExecutor.SplitParams memory params = SplitExecutor.SplitParams({
            numerator: 10,
            denominator: 1,
            isReverse: true,
            expectedNewMultiplier: 0.1e18,
            fractionalHandling: 2,
            cashInLieuToken: address(usdc),
            cashInLieuPrice: 50e6
        });
        executor.execute(_buildSplitIntent(intentId, params));

        // Build merkle tree for alice's fractional shares
        bytes32 leaf = keccak256(abi.encodePacked(alice, fractionalAmount));
        bytes32 merkleRoot = leaf;

        // Set merkle root (as registry)
        executor.setCashInLieuMerkle(intentId, merkleRoot, block.timestamp + 90 days);

        // Fund executor with USDC
        usdc.mint(address(executor), 1000e6);

        // Alice claims
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        executor.claimCashInLieu(intentId, fractionalAmount, proof);

        uint256 expectedPayout = (fractionalAmount * 50e6) / 1e18;
        assertEq(usdc.balanceOf(alice), expectedPayout);
    }
}
