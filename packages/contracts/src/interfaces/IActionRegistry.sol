// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "./ICorpActionTypes.sol";

interface IActionRegistry {
    function proposeAction(
        ICorpActionTypes.ActionIntent calldata intent,
        bytes calldata signature
    ) external returns (bytes32 intentId);

    function validateAction(
        bytes32 intentId,
        bytes calldata signature
    ) external;

    function executeAction(bytes32 intentId) external;

    function cancelAction(bytes32 intentId, string calldata reason) external;

    function getAction(bytes32 intentId)
        external view returns (ICorpActionTypes.ActionIntent memory);

    function getActionsByToken(address token)
        external view returns (bytes32[] memory);

    function getValidationCount(bytes32 intentId)
        external view returns (uint256);

    function getExecutionTime(bytes32 intentId)
        external view returns (uint256);

    function updateTokenMapping(
        bytes32 intentId,
        address oldToken,
        address newToken
    ) external;
}
