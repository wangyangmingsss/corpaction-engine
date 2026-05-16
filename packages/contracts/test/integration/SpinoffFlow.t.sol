// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {SpinoffExecutor} from "../../src/executors/SpinoffExecutor.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SpinoffFlowTest is Test {
    ActionRegistry registry;
    SpinoffExecutor executor;
    MockValidatorManager validators;
    MockERC20 parentToken;
    MockERC20 spinoffToken;

    address[] validatorAddrs;
    uint256[] validatorKeys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        parentToken = new MockERC20("AT&T Inc.", "T", 18);
        spinoffToken = new MockERC20("Warner Bros Discovery", "WBD", 18);

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
        validators.setQuorumForType(ICorpActionTypes.ActionType.SPINOFF, 2);
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

        // Deploy SpinoffExecutor via proxy
        SpinoffExecutor execImpl = new SpinoffExecutor();
        bytes memory execInit = abi.encodeWithSelector(
            SpinoffExecutor.initialize.selector,
            address(registry)
        );
        ERC1967Proxy execProxy = new ERC1967Proxy(address(execImpl), execInit);
        executor = SpinoffExecutor(address(execProxy));

        // Register executor and set timelock to 0 for testing
        registry.registerExecutor(
            ICorpActionTypes.ActionType.SPINOFF,
            address(executor)
        );
        registry.setTimelock(ICorpActionTypes.ActionType.SPINOFF, 0);

        // Fund executor with spinoff tokens for distribution
        spinoffToken.mint(address(executor), 1_000_000e18);

        // Give parent tokens to holders
        parentToken.mint(alice, 100e18);
        parentToken.mint(bob, 400e18);
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

    function test_fullSpinoffLifecycle() public {
        // 1:4 spinoff -- Alice gets 25e18, Bob gets 100e18
        uint256 aliceAmount = 25e18;
        uint256 bobAmount = 100e18;

        (bytes32 merkleRoot, bytes32[] memory aliceProof, bytes32[] memory bobProof) =
            _buildMerkleTree(alice, aliceAmount, bob, bobAmount);

        SpinoffExecutor.SpinoffParams memory params = SpinoffExecutor.SpinoffParams({
            newToken: address(spinoffToken),
            distributionRatioNum: 1,
            distributionRatioDen: 4,
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 90 days
        });

        bytes32 intentId = keccak256("spinoff-att-wbd-2026");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.SPINOFF,
            targetToken: address(parentToken),
            ticker: "T",
            isin: "US00206R1023",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("sec-filing-att-spinoff"),
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

        // --- Claim: Alice ---
        vm.prank(alice);
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);
        assertEq(spinoffToken.balanceOf(alice), aliceAmount);

        // --- Claim: Bob ---
        vm.prank(bob);
        executor.claimSpinoff(intentId, bobAmount, bobProof);
        assertEq(spinoffToken.balanceOf(bob), bobAmount);

        // --- Double claim reverts ---
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            SpinoffExecutor.AlreadyClaimed.selector, intentId, alice
        ));
        executor.claimSpinoff(intentId, aliceAmount, aliceProof);
    }

    function test_merkleVerifiedClaim_rejectsInvalidProof() public {
        uint256 aliceAmount = 25e18;
        uint256 bobAmount = 100e18;

        (bytes32 merkleRoot,,) =
            _buildMerkleTree(alice, aliceAmount, bob, bobAmount);

        SpinoffExecutor.SpinoffParams memory params = SpinoffExecutor.SpinoffParams({
            newToken: address(spinoffToken),
            distributionRatioNum: 1,
            distributionRatioDen: 4,
            merkleRoot: merkleRoot,
            snapshotBlock: block.number,
            claimDeadline: block.timestamp + 90 days
        });

        bytes32 intentId = keccak256("spinoff-merkle-check");

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.SPINOFF,
            targetToken: address(parentToken),
            ticker: "T",
            isin: "US00206R1023",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: abi.encode(params),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });

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

        // Attempt claim with fabricated proof
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("garbage");

        vm.prank(alice);
        vm.expectRevert(SpinoffExecutor.InvalidMerkleProof.selector);
        executor.claimSpinoff(intentId, aliceAmount, badProof);

        // Attempt claim with wrong amount but correct proof structure
        (,bytes32[] memory aliceProof,) =
            _buildMerkleTree(alice, aliceAmount, bob, bobAmount);

        vm.prank(alice);
        vm.expectRevert(SpinoffExecutor.InvalidMerkleProof.selector);
        executor.claimSpinoff(intentId, aliceAmount + 1, aliceProof);
    }
}
