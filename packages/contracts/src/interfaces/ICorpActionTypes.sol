// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICorpActionTypes {
    enum ActionType {
        DIVIDEND, FORWARD_SPLIT, REVERSE_SPLIT,
        MERGER_CASH, MERGER_STOCK, MERGER_HYBRID,
        SPINOFF, DELISTING, LIQUIDATION, TICKER_CHANGE
    }

    enum ActionState {
        PROPOSED, VALIDATED, QUEUED, EXECUTING, EXECUTED,
        FAILED, CANCELLED, REVERSED, PAUSED, EXPIRED
    }

    struct ActionIntent {
        bytes32 intentId;
        ActionType actionType;
        address targetToken;
        string  ticker;
        string  isin;
        uint256 recordDate;
        uint256 exDate;
        uint256 effectiveDate;
        bytes   actionParams;
        bytes32 sourceAttestation;
        ActionState state;
        uint256 createdAt;
        uint256 executedAt;
    }
}
