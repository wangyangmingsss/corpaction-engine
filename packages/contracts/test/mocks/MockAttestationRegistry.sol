// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAttestationRegistry} from "../../src/interfaces/IAttestationRegistry.sol";

contract MockAttestationRegistry is IAttestationRegistry {
    mapping(bytes32 => bool) private _verified;
    mapping(bytes32 => bytes32[]) private _intentAttestations;

    function setVerified(bytes32 attestationId, bool verified) external {
        _verified[attestationId] = verified;
    }

    function addAttestationForIntent(bytes32 intentId, bytes32 attestationId) external {
        _intentAttestations[intentId].push(attestationId);
    }

    function isVerified(bytes32 attestationId) external view override returns (bool) {
        return _verified[attestationId];
    }

    function getAttestationsForIntent(bytes32 intentId) external view override returns (bytes32[] memory) {
        return _intentAttestations[intentId];
    }
}
