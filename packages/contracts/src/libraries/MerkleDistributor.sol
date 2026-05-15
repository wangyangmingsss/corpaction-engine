// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

library MerkleDistributor {
    function computeLeaf(
        address account,
        uint256 amount
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(account, amount)))
        );
    }

    function verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        address account,
        uint256 amount
    ) internal pure returns (bool) {
        bytes32 leaf = computeLeaf(account, amount);
        return MerkleProof.verify(proof, root, leaf);
    }
}
