// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {IFeeCollector} from "../../src/interfaces/IFeeCollector.sol";

contract MockFeeCollector is IFeeCollector {
    uint256 public lastFeeCollected;

    function collectFee(bytes32, ICorpActionTypes.ActionType, uint256, address) external override returns (uint256) {
        lastFeeCollected = 0; // no-op for testing
        return 0;
    }
}
