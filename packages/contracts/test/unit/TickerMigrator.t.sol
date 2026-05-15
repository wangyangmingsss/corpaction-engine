// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickerMigrator} from "../../src/executors/TickerMigrator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TickerMigratorTest is Test {
    TickerMigrator public migrator;
    MockERC20 public oldToken;
    MockERC20 public newToken;

    address public registry = address(this);
    address public alice = makeAddr("alice");

    uint256 public aliceAmount = 100e18;
    bytes32 public merkleRoot;
    bytes32[] public aliceProof;

    function setUp() public {
        oldToken = new MockERC20("Facebook", "FB", 18);
        newToken = new MockERC20("Meta Platforms", "META", 18);

        TickerMigrator impl = new TickerMigrator();
        bytes memory initData = abi.encodeWithSelector(
            TickerMigrator.initialize.selector, registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        migrator = TickerMigrator(address(proxy));

        newToken.mint(address(migrator), 1_000_000e18);

        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        merkleRoot = aliceLeaf;
        aliceProof = new bytes32[](0);
    }

    function _buildMigrationIntent(bytes32 intentId, uint256 deadline)
        internal view returns (ICorpActionTypes.ActionIntent memory)
    {
        TickerMigrator.TickerMigrationParams memory params = TickerMigrator.TickerMigrationParams({
            newToken: address(newToken),
            newTicker: "META",
            newName: "Meta Platforms Inc.",
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: deadline
        });

        return ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.TICKER_CHANGE,
            targetToken: address(oldToken),
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
    }

    function test_executeInitialization() public {
        bytes32 intentId = keccak256("migrate-1");
        bytes memory result = migrator.execute(
            _buildMigrationIntent(intentId, block.timestamp + 90 days)
        );

        (address old, address newT, string memory ticker) =
            abi.decode(result, (address, address, string));

        assertEq(old, address(oldToken));
        assertEq(newT, address(newToken));
        assertEq(ticker, "META");

        (,, bool initialized,) = migrator.migrations(intentId);
        assertTrue(initialized);
    }

    function test_claimMigration() public {
        bytes32 intentId = keccak256("migrate-claim");
        migrator.execute(_buildMigrationIntent(intentId, block.timestamp + 90 days));

        vm.prank(alice);
        migrator.claimMigration(intentId, aliceAmount, aliceProof);
        assertEq(newToken.balanceOf(alice), aliceAmount);
    }

    function test_revert_invalidProof() public {
        bytes32 intentId = keccak256("migrate-bad");
        migrator.execute(_buildMigrationIntent(intentId, block.timestamp + 90 days));

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("garbage");

        vm.prank(alice);
        vm.expectRevert(TickerMigrator.InvalidMerkleProof.selector);
        migrator.claimMigration(intentId, aliceAmount, badProof);
    }

    function test_revert_afterDeadline() public {
        bytes32 intentId = keccak256("migrate-expired");
        uint256 deadline = block.timestamp + 90 days;
        migrator.execute(_buildMigrationIntent(intentId, deadline));

        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TickerMigrator.ClaimExpired.selector, intentId
        ));
        migrator.claimMigration(intentId, aliceAmount, aliceProof);
    }

    function test_revert_doubleClaim() public {
        bytes32 intentId = keccak256("migrate-double");
        migrator.execute(_buildMigrationIntent(intentId, block.timestamp + 90 days));

        vm.prank(alice);
        migrator.claimMigration(intentId, aliceAmount, aliceProof);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TickerMigrator.AlreadyClaimed.selector, intentId, alice
        ));
        migrator.claimMigration(intentId, aliceAmount, aliceProof);
    }

    function test_revert_notInitialized() public {
        bytes32 intentId = keccak256("migrate-missing");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TickerMigrator.NotInitialized.selector, intentId
        ));
        migrator.claimMigration(intentId, aliceAmount, aliceProof);
    }
}
