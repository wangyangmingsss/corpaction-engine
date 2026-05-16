// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActionRegistry} from "../../src/core/ActionRegistry.sol";
import {MockValidatorManager} from "../mocks/MockValidatorManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EmergencyPauseTest is Test {
    ActionRegistry registry;
    MockValidatorManager validators;
    MockERC20 stockToken;

    address[] validatorAddrs;
    uint256[] validatorKeys;

    function setUp() public {
        stockToken = new MockERC20("Test", "TST", 18);

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
        validators.setQuorumForType(ICorpActionTypes.ActionType.DIVIDEND, 2);
        validators.setSuperMaj(4);

        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector, address(validators), 7 days
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = ActionRegistry(address(regProxy));
    }

    function _buildIntent(bytes32 intentId) internal view returns (ICorpActionTypes.ActionIntent memory) {
        return ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "TST",
            isin: "US0000000000",
            recordDate: block.timestamp + 1 days,
            exDate: block.timestamp + 2 days,
            effectiveDate: block.timestamp + 3 days,
            actionParams: abi.encode(uint256(100e6)),
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.PROPOSED,
            createdAt: 0,
            executedAt: 0
        });
    }

    function test_pauseBlocksProposals() public {
        // Pause
        vm.prank(validatorAddrs[0]);
        registry.emergencyPause();
        assertTrue(registry.paused());

        // Try to propose - should revert
        ICorpActionTypes.ActionIntent memory intent = _buildIntent(keccak256("paused-intent"));
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );

        vm.expectRevert(); // EnforcedPause
        registry.proposeAction(intent, abi.encodePacked(r, s, v));
    }

    function test_resumeWithSuperMajority() public {
        // Pause
        vm.prank(validatorAddrs[0]);
        registry.emergencyPause();
        assertTrue(registry.paused());

        // Build resume signatures (need 4 = superMajority)
        bytes32 resumeHash = keccak256(
            abi.encodePacked("EMERGENCY_RESUME", block.chainid, address(registry))
        );

        bytes[] memory sigs = new bytes[](4);
        for (uint i = 0; i < 4; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(
                validatorKeys[i],
                keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", resumeHash))
            );
            sigs[i] = abi.encodePacked(r, s, v);
        }

        registry.emergencyResume(sigs);
        assertFalse(registry.paused());
    }

    function test_resumeAndContinueOperations() public {
        // Pause
        vm.prank(validatorAddrs[0]);
        registry.emergencyPause();

        // Resume
        bytes32 resumeHash = keccak256(
            abi.encodePacked("EMERGENCY_RESUME", block.chainid, address(registry))
        );
        bytes[] memory sigs = new bytes[](4);
        for (uint i = 0; i < 4; i++) {
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(
                validatorKeys[i],
                keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", resumeHash))
            );
            sigs[i] = abi.encodePacked(r2, s2, v2);
        }
        registry.emergencyResume(sigs);

        // Verify normal operations resume
        ICorpActionTypes.ActionIntent memory intent = _buildIntent(keccak256("resumed-intent"));
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );

        bytes32 id = registry.proposeAction(intent, abi.encodePacked(r, s, v));
        assertEq(id, intent.intentId);
    }

    function test_revert_resumeInsufficientSignatures() public {
        vm.prank(validatorAddrs[0]);
        registry.emergencyPause();

        bytes32 resumeHash = keccak256(
            abi.encodePacked("EMERGENCY_RESUME", block.chainid, address(registry))
        );

        // Only 2 signatures, need 4
        bytes[] memory sigs = new bytes[](2);
        for (uint i = 0; i < 2; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(
                validatorKeys[i],
                keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", resumeHash))
            );
            sigs[i] = abi.encodePacked(r, s, v);
        }

        vm.expectRevert("Insufficient signatures");
        registry.emergencyResume(sigs);
    }

    function test_pauseBlocksValidation() public {
        // First propose while unpaused
        ICorpActionTypes.ActionIntent memory intent = _buildIntent(keccak256("val-pause-test"));
        bytes32 intentHash = keccak256(abi.encode(intent));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            validatorKeys[0],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", intentHash))
        );
        registry.proposeAction(intent, abi.encodePacked(r, s, v));

        // Now pause
        vm.prank(validatorAddrs[0]);
        registry.emergencyPause();

        // Try to validate - should fail
        bytes32 valHash = keccak256(abi.encode(
            intent.intentId, intent.actionType, intent.targetToken, intent.actionParams
        ));
        (v, r, s) = vm.sign(
            validatorKeys[1],
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", valHash))
        );

        vm.expectRevert(); // EnforcedPause
        registry.validateAction(intent.intentId, abi.encodePacked(r, s, v));
    }
}
