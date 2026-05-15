// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAttestationRegistry {
    function getAttestationsForIntent(bytes32 intentId) external view returns (bytes32[] memory);
    function isVerified(bytes32 attestationId) external view returns (bool);
}
