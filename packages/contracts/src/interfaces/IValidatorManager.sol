// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "./ICorpActionTypes.sol";

interface IValidatorManager {
    function isValidator(address account) external view returns (bool);
    function getQuorum(ICorpActionTypes.ActionType actionType)
        external view returns (uint256);
    function getSuperMajority() external view returns (uint256);
    function recoverSigner(bytes32 hash, bytes calldata signature)
        external pure returns (address);
    function getValidatorCount() external view returns (uint256);
}
