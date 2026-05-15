// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IValidatorManager} from "../../src/interfaces/IValidatorManager.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";

contract MockValidatorManager is IValidatorManager {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    mapping(address => bool) public validators;
    mapping(ICorpActionTypes.ActionType => uint256) public quorums;
    uint256 public superMajority;
    uint256 public validatorCount;

    function addValidator(address v) external {
        validators[v] = true;
        validatorCount++;
    }

    function setQuorumForType(ICorpActionTypes.ActionType t, uint256 q) external {
        quorums[t] = q;
    }

    function setSuperMaj(uint256 s) external {
        superMajority = s;
    }

    function isValidator(address account) external view override returns (bool) {
        return validators[account];
    }

    function getQuorum(ICorpActionTypes.ActionType actionType) external view override returns (uint256) {
        return quorums[actionType];
    }

    function getSuperMajority() external view override returns (uint256) {
        return superMajority;
    }

    function getValidatorCount() external view override returns (uint256) {
        return validatorCount;
    }

    function recoverSigner(bytes32 hash, bytes calldata signature) external pure override returns (address) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        return ethSignedHash.recover(signature);
    }
}
