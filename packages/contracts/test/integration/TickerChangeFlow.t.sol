// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {TickerMigrator} from "../../src/executors/TickerMigrator.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev A minimal pausable ERC-20 used to verify the old-token freeze path.
contract MockPausableERC20 is MockERC20 {
    bool public paused;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) MockERC20(name_, symbol_, decimals_) {}

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }
}

contract TickerChangeFlowTest is Test {
    ActionRegistry registry;
    TickerMigrator migrator;
    MockValidatorManager validators;
    MockPausableERC20 oldToken;
    MockERC20 newToken;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        oldToken = new MockPausableERC20("Facebook Inc.", "FB", 18);
        newToken = new MockERC20("Meta Platforms Inc.", "META", 18);

        // Setup validators
        for (uint i = 0; i < 5; i++) {
            (address addr, uint256 key) = makeAddrAndKey(
                string(abi.encodePacked("validator", vm.toString(i)))
            );
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }

        validators = new MockValidatorManager();
        for (uint i = 0; i < 5; i++) {
            validators.addValidator(validatorAddrs[i]);
        }
        validators.setQuorumForType(ICorpActionTypes.ActionType.TICKER_CHANGE, 2);
        validators.setSuperMaj(4);

        // Deploy ActionRegistry via proxy
        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector,
            address(validators),
            7 days
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = ActionRegistry(address(regProxy));

        // Deploy TickerMigrator via proxy
        TickerMigrator migImpl = new TickerMigrator();
        bytes memory migInit = abi.encodeWithSelector(
            TickerMigrator.initialize.selector,
            address(registry)
        );
        ERC1967Proxy migProxy = new ERC1967Proxy(address(migImpl), migInit);
        migrator = TickerMigrator(address(migProxy));

        // Register executor and set timelock to 0 for testing
        registry.registerExecutor(
            ICorpActionTypes.ActionType.TICKER_CHANGE,
            address(migrator)
        );
        registry.setTimelock(ICorpActionTypes.ActionType.TICKER_CHANGE, 0);

        // Fund migrator with new tokens for distribution
        newToken.mint(address(migrator), 1_000_000e18);

        // Give old tokens to holders
        oldToken.mint(alice, 100e18);
        oldToken.mint(bob, 250e18);
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function _buildMerkleTree(
        address holder1, uint256 amt1,
        address holder2, uint256 amt2
    ) internal pure returns (
        bytes32 root,
        bytes32[] memory proof1,
        bytes32[] memory proof2
    ) {
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(holder1, amt1))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(holder2, amt2))));

        proof1 = new bytes32[](1);
        proof2 = new bytes32[](1);

        if (leaf1 <= leaf2) {
            root = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            root = keccak256(abi.encodePacked(leaf2, leaf1));
        }
        proof1[0] = leaf2;
        proof2[0] = leaf1;
    }

    function _signPropose(
        ICorpActionTypes.ActionIntent memory intent,
        uint256 key
    ) internal pure returns (bytes memory) {
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        return abi.encodePacked(r, s, v);
    }

    function _signValidate(
        bytes32 intentId,
        ICorpActionTypes.ActionType actionType,
        address targetToken,
        bytes memory actionParams,
        uint256 key
    ) internal pure returns (bytes memory) {
        bytes32 valHash = keccak256(abi.encode(
            intentId, actionType, targetToken, actionParams
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );
        return abi.encodePacked(r, s, v);
    }

    // ── Tests ───────────────────────────────────────────────────────────

    function test_fullTickerChangeLifecycle() public {
        uint256 aliceAmount = 100e18;
        uint256 bobAmount = 250e18;

        (bytes32 merkleRoot, bytes32[] memory aliceProof, bytes32[] memory bobProof) =
            _buildMerkleTree(alice, aliceAmount, bob, bobAmount);

        TickerMigrator.TickerMigrationParams memory params = TickerMigrator.TickerMigrationParams({
            newToken: address(newToken),
            newTicker: "META",
            newName: "Meta Platforms Inc.",
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 90 days
        });

        bytes32 intentId = keccak256("ticker-fb-to-meta-2026");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.TICKER_CHANGE,
            targetToken: address(oldToken),
            ticker: "FB",
            isin: "US30303M1027",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("sec-filing-meta-ticker"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // --- Propose ---
        registry.proposeAction(intent, _signPropose(intent, validatorKeys[0]));

        // --- Validate (reaches quorum of 2) ---
        registry.validateAction(
            intentId,
            _signValidate(
                intentId, intent.actionType,
                intent.targetToken, intent.actionParams,
                validatorKeys[1]
            )
        );

        // --- Execute ---
        registry.executeAction(intentId);

        // Verify state is EXECUTED
        ICorpActionTypes.ActionIntent memory stored = registry.getAction(intentId);
        assertEq(uint8(stored.state), uint8(ICorpActionTypes.ActionState.EXECUTED));

        // Verify old token is paused (frozen)
        assertTrue(oldToken.paused(), "Old token should be paused after execution");

        // Verify token mapping was updated in the registry
        assertEq(
            registry.tokenMapping(address(oldToken)),
            address(newToken),
            "Registry token mapping should point old -> new"
        );

        // --- Claim migration: Alice ---
        vm.prank(alice);
        migrator.claimMigration(intentId, aliceAmount, aliceProof);
        assertEq(newToken.balanceOf(alice), aliceAmount);

        // --- Claim migration: Bob ---
        vm.prank(bob);
        migrator.claimMigration(intentId, bobAmount, bobProof);
        assertEq(newToken.balanceOf(bob), bobAmount);

        // --- Double claim reverts ---
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TickerMigrator.AlreadyClaimed.selector, intentId, alice
        ));
        migrator.claimMigration(intentId, aliceAmount, aliceProof);
    }

    function test_oldTokenPaused_newTokenActive() public {
        uint256 aliceAmount = 100e18;

        // Single-leaf merkle tree for alice
        bytes32 aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmount))));
        bytes32 merkleRoot = aliceLeaf;

        TickerMigrator.TickerMigrationParams memory params = TickerMigrator.TickerMigrationParams({
            newToken: address(newToken),
            newTicker: "META",
            newName: "Meta Platforms Inc.",
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 90 days
        });

        bytes32 intentId = keccak256("ticker-pause-check");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
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
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

        // Verify old token is NOT paused before execution
        assertFalse(oldToken.paused(), "Old token should not be paused before execution");

        // Propose + validate + execute
        registry.proposeAction(intent, _signPropose(intent, validatorKeys[0]));
        registry.validateAction(
            intentId,
            _signValidate(
                intentId, intent.actionType,
                intent.targetToken, intent.actionParams,
                validatorKeys[1]
            )
        );
        registry.executeAction(intentId);

        // Old token is paused
        assertTrue(oldToken.paused(), "Old token must be paused after ticker change");

        // New token is active -- alice can receive and transfer new tokens
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        migrator.claimMigration(intentId, aliceAmount, proof);

        assertEq(newToken.balanceOf(alice), aliceAmount);

        // New token transfer works (active)
        vm.prank(alice);
        newToken.transfer(bob, 10e18);
        assertEq(newToken.balanceOf(bob), 10e18);
        assertEq(newToken.balanceOf(alice), aliceAmount - 10e18);
    }
}
