// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DelistingManager} from "../../src/executors/DelistingManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DelistingManagerTest is Test {
    DelistingManager public mgr;
    MockERC20 public usdc;
    MockERC20 public stockToken;

    address public registry = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public aliceAmount = 5000e6;
    bytes32 public merkleRoot;
    bytes32[] public aliceProof;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        stockToken = new MockERC20("TWTR", "TWTR", 18);

        DelistingManager impl = new DelistingManager();
        bytes memory initData = abi.encodeWithSelector(
            DelistingManager.initialize.selector, registry, address(0xBEEF)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        mgr = DelistingManager(address(proxy));

        usdc.mint(address(mgr), 1_000_000e6);

        // Single-leaf merkle tree for alice
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        merkleRoot = aliceLeaf;
        aliceProof = new bytes32[](0);
    }

    function _initDelisting(bytes32 intentId) internal returns (DelistingManager.DelistingParams memory) {
        DelistingManager.DelistingParams memory params = DelistingManager.DelistingParams({
            announcementTime: block.timestamp,
            sellOnlyTime: block.timestamp + 48 hours,
            priceLockTime: block.timestamp + 72 hours,
            finalPrice: 54_200_000, // $54.20
            settlementToken: address(usdc),
            merkleRoot: merkleRoot,
            totalPool: 500_000e6,
            claimDeadline: block.timestamp + 180 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DELISTING,
            targetToken: address(stockToken),
            ticker: "TWTR",
            isin: "US90184L1026",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        mgr.execute(intent);
        return params;
    }

    function test_phase_announced() public {
        bytes32 intentId = keccak256("delist-1");
        _initDelisting(intentId);

        (, DelistingManager.DelistingPhase phase, bool initialized,,,,) = mgr.delistings(intentId);
        assertTrue(initialized);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.ANNOUNCED));
    }

    function test_phase_sellOnly() public {
        bytes32 intentId = keccak256("delist-2");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);

        (, DelistingManager.DelistingPhase phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.SELL_ONLY));
    }

    function test_phase_priceLocked() public {
        bytes32 intentId = keccak256("delist-3");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);

        vm.warp(params.priceLockTime);
        mgr.advancePhase(intentId);

        (, DelistingManager.DelistingPhase phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.PRICE_LOCKED));
    }

    function test_phase_liquidating() public {
        bytes32 intentId = keccak256("delist-4");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);
        vm.warp(params.priceLockTime);
        mgr.advancePhase(intentId);
        mgr.advancePhase(intentId); // PRICE_LOCKED -> LIQUIDATING

        (, DelistingManager.DelistingPhase phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.LIQUIDATING));
    }

    function test_phase_frozen() public {
        bytes32 intentId = keccak256("delist-5");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);
        vm.warp(params.priceLockTime);
        mgr.advancePhase(intentId);
        mgr.advancePhase(intentId);
        mgr.freezeToken(intentId);

        (, DelistingManager.DelistingPhase phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.FROZEN));
    }

    function test_claimLiquidation() public {
        bytes32 intentId = keccak256("delist-claim");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        // Advance to LIQUIDATING
        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);
        vm.warp(params.priceLockTime);
        mgr.advancePhase(intentId);
        mgr.advancePhase(intentId);

        vm.prank(alice);
        mgr.claimLiquidation(intentId, aliceAmount, aliceProof);
        assertEq(usdc.balanceOf(alice), aliceAmount);
    }

    function test_disputeMechanism() public {
        bytes32 intentId = keccak256("delist-dispute");
        _initDelisting(intentId);

        mgr.disputeDelisting(intentId, "Pricing is unfair");

        (,,,,,bool disputed,) = mgr.delistings(intentId);
        assertTrue(disputed);
    }

    function test_rollbackAfterDispute() public {
        bytes32 intentId = keccak256("delist-rollback");
        _initDelisting(intentId);

        mgr.disputeDelisting(intentId, "Pricing is unfair");
        mgr.rollbackDelisting(intentId);

        (, DelistingManager.DelistingPhase phase, bool initialized,,,,) = mgr.delistings(intentId);
        assertFalse(initialized);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.NONE));
    }

    function test_revert_skippedPhase() public {
        bytes32 intentId = keccak256("delist-skip");
        _initDelisting(intentId);

        // Try to advance before sellOnlyTime -- should not change phase
        // since the condition won't match, the function just doesn't advance
        mgr.advancePhase(intentId);
        (, DelistingManager.DelistingPhase phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.ANNOUNCED));
    }

    function test_revert_claimAfterDeadline() public {
        bytes32 intentId = keccak256("delist-expired");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);
        vm.warp(params.priceLockTime);
        mgr.advancePhase(intentId);
        mgr.advancePhase(intentId);

        vm.warp(params.claimDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            DelistingManager.ClaimDeadlineExpired.selector, intentId
        ));
        mgr.claimLiquidation(intentId, aliceAmount, aliceProof);
    }

    function test_revert_claimDuringDispute() public {
        bytes32 intentId = keccak256("delist-disp-claim");
        DelistingManager.DelistingParams memory params = _initDelisting(intentId);

        vm.warp(params.sellOnlyTime);
        mgr.advancePhase(intentId);
        vm.warp(params.priceLockTime);
        mgr.advancePhase(intentId);
        mgr.advancePhase(intentId);

        mgr.disputeDelisting(intentId, "Under review");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            DelistingManager.DelistingIsDisputed.selector, intentId
        ));
        mgr.claimLiquidation(intentId, aliceAmount, aliceProof);
    }
}
