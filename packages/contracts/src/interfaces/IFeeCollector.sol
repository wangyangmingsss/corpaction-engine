// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "./ICorpActionTypes.sol";

interface IFeeCollector {
    function collectFee(ICorpActionTypes.ActionType actionType, uint256 holderCount) external returns (uint256);
}
