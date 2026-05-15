// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MergerHandler} from "../../src/executors/MergerHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MergerHandlerTest is Test {
    MergerHandler public handler;
    MockERC20 public sourceToken;
    MockERC20 public acquiringToken;
    MockERC20 public cashToken;

    address public registry = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public aliceShares = 100e18;
    uint256 public bobShares = 250e18;

    bytes32 public merkleRoot;
    bytes32[] public aliceProof;
    bytes32[] public bobProof;

    function setUp() public {
        sourceToken = new MockERC20("Source", "SRC", 18);
        acquiringToken = new MockERC20("Acquiring", "ACQ", 18);
        cashToken = new MockERC20("USDC", "USDC", 6);

        MergerHandler impl = new MergerHandler();
        bytes memory initData = abi.encodeWithSelector(
            MergerHandler.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        handler = MergerHandler(address(proxy));

        // Fund handler
        acquiringToken.mint(address(handler), 1_000_000e18);
        cashToken.mint(address(handler), 1_000_000e6);

        // Build merkle tree
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceShares))));
        bytes32 bobLeaf = keccak256(bytes.concat(keccak256(abi.encode(bob, bobShares))));

        aliceProof = new bytes32[](1);
        bobProof = new bytes32[](1);

        if (aliceLeaf <= bobLeaf) {
            merkleRoot = keccak256(abi.encodePacked(aliceLeaf, bobLeaf));
            aliceProof[0] = bobLeaf;
            bobProof[0] = aliceLeaf;
        } else {
            merkleRoot = keccak256(abi.encodePacked(bobLeaf, aliceLeaf));
            aliceProof[0] = bobLeaf;
            bobProof[0] = aliceLeaf;
        }
    }

    function _buildMergerIntent(
        bytes32 intentId,
        MergerHandler.MergerParams memory params
    ) internal view returns (ICorpActionTypes.ActionIntent memory) {
        return ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.MERGER_STOCK,
            targetToken: address(sourceToken),
            ticker: "SRC",
            isin: "XX0000000000",
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

    function test_execute_cashOnlyMerger() public {
        bytes32 intentId = keccak256("merger-cash");
        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.CASH_ONLY,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 0,
            exchangeRatioDen: 1,
            cashPerShare: 50e6,
            cashToken: address(cashToken),
            electionDeadline: 0,
            hasElection: false,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 500_000e6
        });

        handler.execute(_buildMergerIntent(intentId, params));

        vm.prank(alice);
        handler.claimMerger(intentId, aliceShares, aliceProof);

        uint256 expectedCash = (aliceShares * 50e6) / 1e18;
        assertEq(cashToken.balanceOf(alice), expectedCash);
    }

    function test_execute_stockForStockMerger() public {
        bytes32 intentId = keccak256("merger-stock");
        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.STOCK_FOR_STOCK,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 3,
            exchangeRatioDen: 2,
            cashPerShare: 0,
            cashToken: address(cashToken),
            electionDeadline: 0,
            hasElection: false,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 0
        });

        handler.execute(_buildMergerIntent(intentId, params));

        vm.prank(alice);
        handler.claimMerger(intentId, aliceShares, aliceProof);

        uint256 expectedStock = (aliceShares * 3) / 2;
        assertEq(acquiringToken.balanceOf(alice), expectedStock);
    }

    function test_execute_hybridMerger() public {
        bytes32 intentId = keccak256("merger-hybrid");
        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.HYBRID,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 1,
            exchangeRatioDen: 1,
            cashPerShare: 10e6,
            cashToken: address(cashToken),
            electionDeadline: 0,
            hasElection: false,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 100_000e6
        });

        handler.execute(_buildMergerIntent(intentId, params));

        vm.prank(alice);
        handler.claimMerger(intentId, aliceShares, aliceProof);

        uint256 expectedCash = (aliceShares * 10e6) / 1e18;
        uint256 expectedStock = aliceShares; // 1:1
        assertEq(cashToken.balanceOf(alice), expectedCash);
        assertEq(acquiringToken.balanceOf(alice), expectedStock);
    }

    function test_electionMechanism() public {
        bytes32 intentId = keccak256("merger-election");
        uint256 deadline = block.timestamp + 7 days;

        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.HYBRID,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 1,
            exchangeRatioDen: 1,
            cashPerShare: 50e6,
            cashToken: address(cashToken),
            electionDeadline: deadline,
            hasElection: true,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 500_000e6
        });

        handler.execute(_buildMergerIntent(intentId, params));

        // Alice elects cash (option 0 = cash)
        vm.prank(alice);
        handler.electMergerOption(intentId, 0);

        // Bob elects stock (option 1 = stock)
        vm.prank(bob);
        handler.electMergerOption(intentId, 1);

        // Warp past deadline
        vm.warp(deadline + 1);

        // Alice claims cash
        vm.prank(alice);
        handler.claimMerger(intentId, aliceShares, aliceProof);
        uint256 expectedCash = (aliceShares * 50e6) / 1e18;
        assertEq(cashToken.balanceOf(alice), expectedCash);

        // Bob claims stock
        vm.prank(bob);
        handler.claimMerger(intentId, bobShares, bobProof);
        assertEq(acquiringToken.balanceOf(bob), bobShares); // 1:1
    }

    function test_prorationFactor() public {
        bytes32 intentId = keccak256("merger-proration");
        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.CASH_ONLY,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 0,
            exchangeRatioDen: 1,
            cashPerShare: 100e6,
            cashToken: address(cashToken),
            electionDeadline: 0,
            hasElection: false,
            prorationFactor: 8000, // 80%
            merkleRoot: merkleRoot,
            totalCashPool: 500_000e6
        });

        handler.execute(_buildMergerIntent(intentId, params));

        vm.prank(alice);
        handler.claimMerger(intentId, aliceShares, aliceProof);

        uint256 fullCash = (aliceShares * 100e6) / 1e18;
        uint256 prorated = (fullCash * 8000) / 10000;
        assertEq(cashToken.balanceOf(alice), prorated);
    }

    function test_finalizeMerger() public {
        bytes32 intentId = keccak256("merger-finalize");
        uint256 deadline = block.timestamp + 7 days;

        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.HYBRID,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 1,
            exchangeRatioDen: 1,
            cashPerShare: 50e6,
            cashToken: address(cashToken),
            electionDeadline: deadline,
            hasElection: true,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 500_000e6
        });

        handler.execute(_buildMergerIntent(intentId, params));

        vm.warp(deadline + 1);
        handler.finalizeMerger(intentId);

        // Verify completed via state read
        (,bool initialized,,,bool completed) = handler.mergers(intentId);
        assertTrue(initialized);
        assertTrue(completed);
    }

    function test_revert_claimWithoutElection() public {
        bytes32 intentId = keccak256("merger-no-elect");
        uint256 deadline = block.timestamp + 7 days;

        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.HYBRID,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 1,
            exchangeRatioDen: 1,
            cashPerShare: 50e6,
            cashToken: address(cashToken),
            electionDeadline: deadline,
            hasElection: true,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 500_000e6
        });

        handler.execute(_buildMergerIntent(intentId, params));

        vm.warp(deadline + 1);

        // Try to claim without making an election
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            MergerHandler.ElectionRequired.selector, intentId
        ));
        handler.claimMerger(intentId, aliceShares, aliceProof);
    }

    function test_revert_insufficientCashPool() public {
        bytes32 intentId = keccak256("merger-no-cash");
        MergerHandler.MergerParams memory params = MergerHandler.MergerParams({
            mergerType: MergerHandler.MergerType.CASH_ONLY,
            acquiringToken: address(acquiringToken),
            exchangeRatioNum: 0,
            exchangeRatioDen: 1,
            cashPerShare: 50e6,
            cashToken: address(cashToken),
            electionDeadline: 0,
            hasElection: false,
            prorationFactor: 10000,
            merkleRoot: merkleRoot,
            totalCashPool: 999_999_999e6 // way more than available
        });

        vm.expectRevert(abi.encodeWithSelector(
            MergerHandler.InsufficientCashBalance.selector,
            intentId, 999_999_999e6, 1_000_000e6
        ));
        handler.execute(_buildMergerIntent(intentId, params));
    }
}
