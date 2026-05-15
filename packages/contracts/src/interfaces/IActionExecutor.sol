// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICorpActionTypes} from "./ICorpActionTypes.sol";

interface IActionExecutor {
    function execute(
        ICorpActionTypes.ActionIntent calldata intent
    ) external returns (bytes memory result);
}
