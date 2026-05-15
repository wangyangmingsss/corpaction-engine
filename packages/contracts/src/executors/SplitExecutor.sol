// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActionExecutor} from "../interfaces/IActionExecutor.sol";
import {ICorpActionTypes} from "../interfaces/ICorpActionTypes.sol";
import {IERC8056} from "../interfaces/IERC8056.sol";
import {MultiplierMath} from "../libraries/MultiplierMath.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract SplitExecutor is IActionExecutor, UUPSUpgradeable {

    struct SplitParams {
        uint256 numerator;
        uint256 denominator;
        bool    isReverse;
        uint256 expectedNewMultiplier;
        uint256 fractionalHandling; // 0=round down, 1=round up, 2=cash-in-lieu
        address cashInLieuToken;
        uint256 cashInLieuPrice;
    }

    address public actionRegistry;

    event SplitExecuted(bytes32 indexed intentId, address indexed token,
        uint256 oldMultiplier, uint256 newMultiplier,
        uint256 numerator, uint256 denominator, bool isReverse);

    error MultiplierMismatch(uint256 expected, uint256 calculated);
    error InvalidSplitRatio(uint256 num, uint256 den);
    error NotERC8056Compliant(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _registry) external initializer {
        __UUPSUpgradeable_init();
        actionRegistry = _registry;
    }

    function execute(
        ICorpActionTypes.ActionIntent calldata intent
    ) external override returns (bytes memory) {
        require(msg.sender == actionRegistry, "Only registry");

        SplitParams memory params = abi.decode(
            intent.actionParams, (SplitParams)
        );
        if (params.numerator == 0 || params.denominator == 0)
            revert InvalidSplitRatio(params.numerator, params.denominator);

        IERC8056 token = IERC8056(intent.targetToken);

        // Verify ERC-8056 compliance
        try token.uiMultiplier() returns (uint256) {} catch {
            revert NotERC8056Compliant(intent.targetToken);
        }

        uint256 oldMultiplier = token.uiMultiplier();
        uint256 newMultiplier;

        if (params.isReverse) {
            newMultiplier = MultiplierMath.divMultiplier(
                oldMultiplier, params.numerator, params.denominator
            );
        } else {
            newMultiplier = MultiplierMath.mulMultiplier(
                oldMultiplier, params.numerator, params.denominator
            );
        }

        // Safety check: verify against pre-calculated value
        if (newMultiplier != params.expectedNewMultiplier)
            revert MultiplierMismatch(
                params.expectedNewMultiplier, newMultiplier
            );

        // Execute the split
        token.setUIMultiplier(newMultiplier);

        emit SplitExecuted(
            intent.intentId, intent.targetToken,
            oldMultiplier, newMultiplier,
            params.numerator, params.denominator, params.isReverse
        );

        return abi.encode(oldMultiplier, newMultiplier);
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == actionRegistry, "Only registry");
    }
}
