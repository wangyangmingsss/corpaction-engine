// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickerMigrator} from "../../src/executors/TickerMigrator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Facebook -> Meta Ticker Migration
/// @notice Simulates the FB -> META ticker change (October 2021)
contract FB_META_TickerChangeTest is Test {
    TickerMigrator public migrator;
    MockERC20 public fbToken;
    MockERC20 public metaToken;

    address public registry = address(this);

    address public retailInvestor = makeAddr("retailInvestor");
    address public mutualFund = makeAddr("mutualFund");
    address public zuckerberg = makeAddr("zuckerberg");

    uint256 constant RETAIL_BALANCE = 100e18;
    uint256 constant MUTUAL_BALANCE = 50_000e18;
    uint256 constant ZUCK_BALANCE = 398_000_000e18; // ~398M shares

    bytes32 public merkleRoot;
    bytes32[] public retailProof;
    bytes32[] public mutualProof;
    bytes32[] public zuckProof;

    function setUp() public {
        fbToken = new MockERC20("Facebook Inc.", "FB", 18);
        metaToken = new MockERC20("Meta Platforms Inc.", "META", 18);

        TickerMigrator impl = new TickerMigrator();
        bytes memory initData = abi.encodeWithSelector(
            TickerMigrator.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        migrator = TickerMigrator(address(proxy));

        metaToken.mint(address(migrator), 500_000_000e18);

        fbToken.mint(retailInvestor, RETAIL_BALANCE);
        fbToken.mint(mutualFund, MUTUAL_BALANCE);
        fbToken.mint(zuckerberg, ZUCK_BALANCE);

        // Build merkle tree
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(retailInvestor, RETAIL_BALANCE))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(mutualFund, MUTUAL_BALANCE))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(zuckerberg, ZUCK_BALANCE))));

        bytes32 pair01 = leaf0 <= leaf1
            ? keccak256(abi.encodePacked(leaf0, leaf1))
            : keccak256(abi.encodePacked(leaf1, leaf0));

        merkleRoot = pair01 <= leaf2
            ? keccak256(abi.encodePacked(pair01, leaf2))
            : keccak256(abi.encodePacked(leaf2, pair01));

        retailProof = new bytes32[](2);
        retailProof[0] = leaf1;
        retailProof[1] = leaf2;

        mutualProof = new bytes32[](2);
        mutualProof[0] = leaf0;
        mutualProof[1] = leaf2;

        zuckProof = new bytes32[](1);
        zuckProof[0] = pair01;
    }

    function test_fbToMetaMigration() public {
        bytes32 intentId = keccak256("fb-meta-ticker-2021");

        TickerMigrator.TickerMigrationParams memory params = TickerMigrator.TickerMigrationParams({
            newToken: address(metaToken),
            newTicker: "META",
            newName: "Meta Platforms Inc.",
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 180 days
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.TICKER_CHANGE,
            targetToken: address(fbToken),
            ticker: "FB",
            isin: "US30303M1027",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("sec-meta-ticker-change-8k"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        bytes memory result = migrator.execute(intent);
        (address oldAddr, address newAddr, string memory newTicker) =
            abi.decode(result, (address, address, string));

        assertEq(oldAddr, address(fbToken));
        assertEq(newAddr, address(metaToken));
        assertEq(newTicker, "META");

        // All holders claim META tokens 1:1
        vm.prank(retailInvestor);
        migrator.claimMigration(intentId, RETAIL_BALANCE, retailProof);
        assertEq(metaToken.balanceOf(retailInvestor), RETAIL_BALANCE);

        vm.prank(mutualFund);
        migrator.claimMigration(intentId, MUTUAL_BALANCE, mutualProof);
        assertEq(metaToken.balanceOf(mutualFund), MUTUAL_BALANCE);

        vm.prank(zuckerberg);
        migrator.claimMigration(intentId, ZUCK_BALANCE, zuckProof);
        assertEq(metaToken.balanceOf(zuckerberg), ZUCK_BALANCE);
    }

    function test_fbToMeta_lateClaimReverts() public {
        bytes32 intentId = keccak256("fb-meta-late");
        uint256 deadline = block.timestamp + 180 days;

        TickerMigrator.TickerMigrationParams memory params = TickerMigrator.TickerMigrationParams({
            newToken: address(metaToken),
            newTicker: "META",
            newName: "Meta Platforms Inc.",
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: deadline
        });

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.TICKER_CHANGE,
            targetToken: address(fbToken),
            ticker: "FB",
            isin: "US30303M1027",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        migrator.execute(intent);

        vm.warp(deadline + 1);

        vm.prank(retailInvestor);
        vm.expectRevert(abi.encodeWithSelector(
            TickerMigrator.ClaimExpired.selector, intentId
        ));
        migrator.claimMigration(intentId, RETAIL_BALANCE, retailProof);
    }
}
