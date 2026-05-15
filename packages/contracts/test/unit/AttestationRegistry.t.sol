// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AttestationRegistry} from "../../src/verification/AttestationRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AttestationRegistryTest is Test {
    AttestationRegistry public registry;

    address public admin = address(this);
    address public attester = makeAddr("attester");
    address public unauthorized = makeAddr("unauthorized");

    function setUp() public {
        AttestationRegistry impl = new AttestationRegistry();
        bytes memory initData = abi.encodeWithSelector(
            AttestationRegistry.initialize.selector
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = AttestationRegistry(address(proxy));

        // Grant attester role
        registry.grantRole(registry.ATTESTER_ROLE(), attester);
    }

    function test_submitAttestation() public {
        bytes32 intentId = keccak256("intent-1");

        vm.prank(attester);
        bytes32 attestationId = registry.submitAttestation(
            intentId,
            "SEC_EDGAR",
            "0001193125-22-123456",
            "https://sec.gov/filing",
            keccak256("document-content"),
            block.timestamp,
            hex"deadbeef"
        );

        AttestationRegistry.Attestation memory att = registry.getAttestation(attestationId);
        assertEq(att.intentId, intentId);
        assertEq(att.attester, attester);
        assertEq(att.sourceType, "SEC_EDGAR");
        assertEq(att.sourceId, "0001193125-22-123456");
        assertFalse(att.verified);
    }

    function test_verifyAttestation() public {
        bytes32 intentId = keccak256("intent-2");

        vm.prank(attester);
        bytes32 attestationId = registry.submitAttestation(
            intentId,
            "DTCC",
            "dtcc-ref-123",
            "https://dtcc.com/ref",
            keccak256("dtcc-doc"),
            block.timestamp,
            hex"cafe"
        );

        vm.prank(attester);
        registry.verifyAttestation(attestationId);

        AttestationRegistry.Attestation memory att = registry.getAttestation(attestationId);
        assertTrue(att.verified);
    }

    function test_getAttestationsForIntent() public {
        bytes32 intentId = keccak256("intent-3");

        vm.startPrank(attester);
        registry.submitAttestation(
            intentId, "SEC_EDGAR", "filing-1", "url1",
            keccak256("doc1"), block.timestamp, hex"aa"
        );
        registry.submitAttestation(
            intentId, "DTCC", "filing-2", "url2",
            keccak256("doc2"), block.timestamp, hex"bb"
        );
        vm.stopPrank();

        bytes32[] memory attestations = registry.getAttestationsForIntent(intentId);
        assertEq(attestations.length, 2);
    }

    function test_revert_unauthorizedSubmit() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.submitAttestation(
            keccak256("intent-x"), "SEC", "id", "url",
            keccak256("doc"), block.timestamp, hex"00"
        );
    }

    function test_revert_unauthorizedVerify() public {
        bytes32 intentId = keccak256("intent-4");

        vm.prank(attester);
        bytes32 attestationId = registry.submitAttestation(
            intentId, "SEC_EDGAR", "filing-3", "url3",
            keccak256("doc3"), block.timestamp, hex"cc"
        );

        vm.prank(unauthorized);
        vm.expectRevert();
        registry.verifyAttestation(attestationId);
    }

    function test_revert_duplicateAttestation() public {
        bytes32 intentId = keccak256("intent-5");

        vm.startPrank(attester);
        registry.submitAttestation(
            intentId, "SEC_EDGAR", "filing-4", "url4",
            keccak256("doc4"), block.timestamp, hex"dd"
        );

        bytes32 expectedId = keccak256(abi.encode(
            intentId, "SEC_EDGAR", "filing-4", keccak256("doc4")
        ));
        vm.expectRevert(abi.encodeWithSelector(
            AttestationRegistry.AttestationAlreadyExists.selector, expectedId
        ));
        registry.submitAttestation(
            intentId, "SEC_EDGAR", "filing-4", "url4",
            keccak256("doc4"), block.timestamp, hex"dd"
        );
        vm.stopPrank();
    }

    function test_revert_verifyNonExistent() public {
        bytes32 fakeId = keccak256("nonexistent");
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(
            AttestationRegistry.AttestationNotFound.selector, fakeId
        ));
        registry.verifyAttestation(fakeId);
    }
}
