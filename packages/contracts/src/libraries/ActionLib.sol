// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";

library ActionLib {
    function computeIntentId(
        string memory sourceType,
        string memory sourceId,
        bytes32 contentHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(sourceType, sourceId, contentHash));
    }

    function isTerminalState(
        ICorpActionTypes.ActionState state
    ) internal pure returns (bool) {
        return state == ICorpActionTypes.ActionState.EXECUTED ||
               state == ICorpActionTypes.ActionState.CANCELLED ||
               state == ICorpActionTypes.ActionState.REVERSED ||
               state == ICorpActionTypes.ActionState.EXPIRED;
    }

    function isCancellableState(
        ICorpActionTypes.ActionState state
    ) internal pure returns (bool) {
        return state == ICorpActionTypes.ActionState.PROPOSED ||
               state == ICorpActionTypes.ActionState.VALIDATED ||
               state == ICorpActionTypes.ActionState.QUEUED ||
               state == ICorpActionTypes.ActionState.FAILED ||
               state == ICorpActionTypes.ActionState.PAUSED;
    }

    function severityLevel(
        ICorpActionTypes.ActionType actionType
    ) internal pure returns (uint8) {
        if (actionType == ICorpActionTypes.ActionType.TICKER_CHANGE) return 1; // Low
        if (actionType == ICorpActionTypes.ActionType.DIVIDEND ||
            actionType == ICorpActionTypes.ActionType.FORWARD_SPLIT ||
            actionType == ICorpActionTypes.ActionType.REVERSE_SPLIT) return 2; // Medium
        return 3; // High (merger, delisting, liquidation, spinoff)
    }
}
