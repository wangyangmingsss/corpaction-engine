// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "./ICorpActionTypes.sol";

interface IFeeCollector {
    function collectFee(bytes32 intentId, ICorpActionTypes.ActionType actionType, uint256 holderCount, address payer) external returns (uint256);
}
