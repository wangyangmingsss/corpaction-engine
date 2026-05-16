// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IAttestationRegistry} from "../interfaces/IAttestationRegistry.sol";

contract AttestationRegistry is
    IAttestationRegistry,
    AccessControlUpgradeable,
    EIP712Upgradeable,
    UUPSUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(bytes32 intentId,string sourceType,string sourceId,string sourceUrl,bytes32 contentHash,uint256 ingestedAt)"
    );

    struct Attestation {
        bytes32 intentId;
        string  sourceType;       // e.g., "SEC_EDGAR", "DTCC"
        string  sourceId;         // e.g., accession number
        string  sourceUrl;        // URL to source document
        bytes32 contentHash;      // SHA-256 of source document
        uint256 ingestedAt;       // Timestamp of ingestion
        uint256 blockNumber;      // Block number at submission
        address attester;         // Who submitted the attestation
        bytes   signature;        // Attester's signature over the attestation
        bool    verified;         // Whether independently verified
    }

    mapping(bytes32 => Attestation) public attestations;
    mapping(bytes32 => bytes32[]) private _intentAttestations;

    event AttestationSubmitted(bytes32 indexed intentId, bytes32 indexed attestationId,
        string sourceType, address indexed attester);
    event AttestationVerified(bytes32 indexed attestationId, address verifier);

    error AttestationAlreadyExists(bytes32 attestationId);
    error AttestationNotFound(bytes32 attestationId);
    error InvalidSignature();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize() external initializer {
        __AccessControl_init();
        __EIP712_init("CorpActionAttestationRegistry", "1");
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ATTESTER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    function hashAttestation(
        bytes32 intentId,
        string calldata sourceType,
        string calldata sourceId,
        string calldata sourceUrl,
        bytes32 contentHash,
        uint256 ingestedAt
    ) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            ATTESTATION_TYPEHASH,
            intentId,
            keccak256(bytes(sourceType)),
            keccak256(bytes(sourceId)),
            keccak256(bytes(sourceUrl)),
            contentHash,
            ingestedAt
        )));
    }

    function submitAttestation(
        bytes32 intentId,
        string calldata sourceType,
        string calldata sourceId,
        string calldata sourceUrl,
        bytes32 contentHash,
        uint256 ingestedAt,
        bytes calldata signature
    ) external onlyRole(ATTESTER_ROLE) returns (bytes32 attestationId) {
        attestationId = keccak256(abi.encode(
            intentId, sourceType, sourceId, contentHash
        ));

        if (attestations[attestationId].blockNumber != 0)
            revert AttestationAlreadyExists(attestationId);

        // Verify EIP-712 typed data signature
        bytes32 digest = hashAttestation(
            intentId, sourceType, sourceId, sourceUrl, contentHash, ingestedAt
        );
        address signer = ECDSA.recover(digest, signature);
        if (signer != msg.sender) revert InvalidSignature();

        attestations[attestationId] = Attestation({
            intentId: intentId,
            sourceType: sourceType,
            sourceId: sourceId,
            sourceUrl: sourceUrl,
            contentHash: contentHash,
            ingestedAt: ingestedAt,
            blockNumber: block.number,
            attester: msg.sender,
            signature: signature,
            verified: false
        });

        _intentAttestations[intentId].push(attestationId);

        emit AttestationSubmitted(intentId, attestationId, sourceType, msg.sender);
    }

    function verifyAttestation(bytes32 attestationId) external onlyRole(ATTESTER_ROLE) {
        Attestation storage att = attestations[attestationId];
        if (att.blockNumber == 0) revert AttestationNotFound(attestationId);
        att.verified = true;
        emit AttestationVerified(attestationId, msg.sender);
    }

    function isVerified(bytes32 attestationId) external view returns (bool) {
        return attestations[attestationId].verified;
    }

    function getAttestationsForIntent(bytes32 intentId)
        external view returns (bytes32[] memory) {
        return _intentAttestations[intentId];
    }

    function getAttestation(bytes32 attestationId)
        external view returns (Attestation memory) {
        return attestations[attestationId];
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
