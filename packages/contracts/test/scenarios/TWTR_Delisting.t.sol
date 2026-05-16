// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DelistingManager} from "../../src/executors/DelistingManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title TWTR Delisting Flow
/// @notice Simulates the Twitter / X Corp delisting at $54.20/share
contract TWTR_DelistingTest is Test {
    DelistingManager public mgr;
    MockERC20 public usdc;
    MockERC20 public twtrToken;

    address public registry = address(this);

    address public retailHolder = makeAddr("retailHolder");
    address public activistFund = makeAddr("activistFund");
    address public indexFund = makeAddr("indexFund");

    uint256 constant PRICE_PER_SHARE = 54_200_000; // $54.20 in USDC
    uint256 constant RETAIL_SHARES = 500;
    uint256 constant ACTIVIST_SHARES = 100_000;
    uint256 constant INDEX_SHARES = 250_000;

    uint256 constant RETAIL_PAYOUT = RETAIL_SHARES * PRICE_PER_SHARE;     // $27,100
    uint256 constant ACTIVIST_PAYOUT = ACTIVIST_SHARES * PRICE_PER_SHARE; // $5,420,000
    uint256 constant INDEX_PAYOUT = INDEX_SHARES * PRICE_PER_SHARE;       // $13,550,000

    bytes32 public merkleRoot;
    bytes32[] public retailProof;
    bytes32[] public activistProof;
    bytes32[] public indexProof;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        twtrToken = new MockERC20("Twitter Inc.", "TWTR", 18);

        DelistingManager impl = new DelistingManager();
        bytes memory initData = abi.encodeWithSelector(
            DelistingManager.initialize.selector, registry, address(0xBEEF)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        mgr = DelistingManager(address(proxy));

        uint256 totalPool = RETAIL_PAYOUT + ACTIVIST_PAYOUT + INDEX_PAYOUT;
        usdc.mint(address(mgr), totalPool);

        // Build merkle tree
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(retailHolder, RETAIL_PAYOUT))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(activistFund, ACTIVIST_PAYOUT))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(indexFund, INDEX_PAYOUT))));

        bytes32 pair01 = leaf0 <= leaf1
            ? keccak256(abi.encodePacked(leaf0, leaf1))
            : keccak256(abi.encodePacked(leaf1, leaf0));

        merkleRoot = pair01 <= leaf2
            ? keccak256(abi.encodePacked(pair01, leaf2))
            : keccak256(abi.encodePacked(leaf2, pair01));

        retailProof = new bytes32[](2);
        retailProof[0] = leaf1;
        retailProof[1] = leaf2;

        activistProof = new bytes32[](2);
        activistProof[0] = leaf0;
        activistProof[1] = leaf2;

        indexProof = new bytes32[](1);
        indexProof[0] = pair01;
    }

    function test_twtrFullDelistingFlow() public {
        bytes32 intentId = keccak256("twtr-delisting-2022");
        uint256 totalPool = RETAIL_PAYOUT + ACTIVIST_PAYOUT + INDEX_PAYOUT;

        uint256 announceTime = block.timestamp;
        uint256 sellOnlyTime = announceTime + 48 hours;
        uint256 priceLockTime = announceTime + 72 hours;

        DelistingManager.DelistingParams memory params = DelistingManager.DelistingParams({
            announcementTime: announceTime,
            sellOnlyTime: sellOnlyTime,
            priceLockTime: priceLockTime,
            finalPrice: PRICE_PER_SHARE,
            settlementToken: address(usdc),
            merkleRoot: merkleRoot,
            totalPool: totalPool,
            claimDeadline: announceTime + 180 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DELISTING,
            targetToken: address(twtrToken),
            ticker: "TWTR",
            isin: "US90184L1026",
            recordDate: announceTime,
            exDate: announceTime,
            effectiveDate: announceTime,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("sec-twtr-delist-8k"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        // Phase 1: ANNOUNCED
        mgr.execute(intent);
        (, DelistingManager.DelistingPhase phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.ANNOUNCED));

        // Phase 2: SELL_ONLY
        vm.warp(sellOnlyTime);
        mgr.advancePhase(intentId);
        (, phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.SELL_ONLY));

        // Phase 3: PRICE_LOCKED
        vm.warp(priceLockTime);
        mgr.advancePhase(intentId);
        (, phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.PRICE_LOCKED));

        // Phase 4: LIQUIDATING
        mgr.advancePhase(intentId);

        // All holders claim
        vm.prank(retailHolder);
        mgr.claimLiquidation(intentId, RETAIL_PAYOUT, retailProof);
        assertEq(usdc.balanceOf(retailHolder), RETAIL_PAYOUT);

        vm.prank(activistFund);
        mgr.claimLiquidation(intentId, ACTIVIST_PAYOUT, activistProof);
        assertEq(usdc.balanceOf(activistFund), ACTIVIST_PAYOUT);

        vm.prank(indexFund);
        mgr.claimLiquidation(intentId, INDEX_PAYOUT, indexProof);
        assertEq(usdc.balanceOf(indexFund), INDEX_PAYOUT);

        // Phase 5: FROZEN
        mgr.freezeToken(intentId);
        (, phase,,,,,) = mgr.delistings(intentId);
        assertEq(uint8(phase), uint8(DelistingManager.DelistingPhase.FROZEN));
    }

    function test_twtrDelisting_disputeAndRollback() public {
        bytes32 intentId = keccak256("twtr-delisting-disputed");
        uint256 totalPool = RETAIL_PAYOUT + ACTIVIST_PAYOUT + INDEX_PAYOUT;

        DelistingManager.DelistingParams memory params = DelistingManager.DelistingParams({
            announcementTime: block.timestamp,
            sellOnlyTime: block.timestamp + 48 hours,
            priceLockTime: block.timestamp + 72 hours,
            finalPrice: PRICE_PER_SHARE,
            settlementToken: address(usdc),
            merkleRoot: merkleRoot,
            totalPool: totalPool,
            claimDeadline: block.timestamp + 180 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DELISTING,
            targetToken: address(twtrToken),
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

        // Dispute: price unfair
        mgr.disputeDelisting(intentId, "Acquisition price below fair market value");

        (,,,,,bool disputed,) = mgr.delistings(intentId);
        assertTrue(disputed);

        // Rollback
        mgr.rollbackDelisting(intentId);
        (, DelistingManager.DelistingPhase phase2, bool initialized,,,,) = mgr.delistings(intentId);
        assertFalse(initialized);
        assertEq(uint8(phase2), uint8(DelistingManager.DelistingPhase.NONE));
    }
}
