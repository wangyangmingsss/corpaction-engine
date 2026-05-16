# Slither Static Analysis Report

**Generated:** 2026-05-16
**Solidity Version:** 0.8.24
**Contracts Analyzed:** 14 (11 core + 3 integration)
**Slither Version:** 0.10.1
**Foundry Version:** 0.3.0

## Summary

| Severity | Count | Addressed |
|----------|-------|-----------|
| High | 0 | N/A |
| Medium | 2 | 2 resolved |
| Low | 5 | 3 resolved, 2 accepted |
| Informational | 8 | Reviewed |

---

## Findings

### Medium Severity

#### M-01: Unchecked ERC-20 Return Value in `DividendDistributor.claimDividend`

- **Detector:** `unchecked-transfer`
- **Contract:** `DividendDistributor` (`src/executors/DividendDistributor.sol#L112-L118`)
- **Status:** RESOLVED (commit `a4e7c31`)

**Description:**
The `claimDividend()` function called `payoutToken.transfer(msg.sender, amount)` without checking the boolean return value. Some ERC-20 tokens (e.g., USDT) do not revert on failure and instead return `false`, which could result in the claim being marked as fulfilled while the actual token transfer silently fails.

**Resolution:**
Replaced raw `transfer()` with OpenZeppelin's `SafeERC20.safeTransfer()`, which reverts on failure. Added explicit balance-before/after assertion in the test suite (`test/unit/DividendDistributor.t.sol`).

---

#### M-02: Missing Reentrancy Guard on `MergerHandler.executeConversion`

- **Detector:** `reentrancy-eth`
- **Contract:** `MergerHandler` (`src/executors/MergerHandler.sol#L87-L134`)
- **Status:** RESOLVED (commit `f92d1a8`)

**Description:**
The `executeConversion()` function performed an external call to the target token contract to mint new shares before updating internal accounting state (`convertedBalances` mapping). A malicious token contract could re-enter and claim additional conversions before the state update.

**Resolution:**
Applied the checks-effects-interactions pattern by moving the `convertedBalances[msg.sender] = true` assignment before the external mint call. Additionally, the `nonReentrant` modifier from `ReentrancyGuard` was already imported but not applied to this function; it has now been added.

---

### Low Severity

#### L-01: Shadowed State Variable in `TimelockController`

- **Detector:** `shadowing-state`
- **Contract:** `TimelockController` (`src/core/TimelockController.sol#L28`)
- **Status:** RESOLVED (commit `c1f8e02`)

**Description:**
The constructor parameter `_delay` shadows the inherited `delay` state variable from the base contract, which could lead to confusion during maintenance.

**Resolution:**
Renamed the constructor parameter to `initialDelay` to eliminate shadowing.

---

#### L-02: Missing Zero-Address Validation in `ValidatorManager.addValidator`

- **Detector:** `missing-zero-check`
- **Contract:** `ValidatorManager` (`src/core/ValidatorManager.sol#L54`)
- **Status:** RESOLVED (commit `c1f8e02`)

**Description:**
The `addValidator(address validator)` function did not check for `address(0)`, which would allow the zero address to be registered as a validator and could corrupt quorum calculations.

**Resolution:**
Added `require(validator != address(0), "ValidatorManager: zero address")` at the start of the function.

---

#### L-03: Block Timestamp Dependency in `ActionRegistry.isTimelockExpired`

- **Detector:** `timestamp`
- **Contract:** `ActionRegistry` (`src/core/ActionRegistry.sol#L198`)
- **Status:** ACCEPTED

**Description:**
The `isTimelockExpired()` function uses `block.timestamp` to determine whether the timelock period has elapsed. Block timestamps can be manipulated by miners/validators within a ~15-second window.

**Justification for Acceptance:**
The timelock periods used by the protocol are a minimum of 24 hours (86,400 seconds). A 15-second manipulation window is negligible relative to the enforced delay and does not pose a meaningful risk. This is standard practice in timelock-based governance contracts.

---

#### L-04: Costly Loop in `DividendDistributor._computeMerkleRoot`

- **Detector:** `costly-loop`
- **Contract:** `DividendDistributor` (`src/executors/DividendDistributor.sol#L138-L147`)
- **Status:** ACCEPTED

**Description:**
The internal `_computeMerkleRoot()` helper iterates over the proof array in a loop. If an excessively large proof is supplied, gas costs could become prohibitive.

**Justification for Acceptance:**
Merkle proofs are bounded by `log2(n)` where `n` is the number of leaves. For the maximum expected holder set (~100,000 addresses), proof length is at most 17 elements. A `MAX_PROOF_LENGTH` constant (32) is enforced at the callsite, making unbounded iteration impossible.

---

#### L-05: Unused Function Parameter in `FeeCollector._calculateFee`

- **Detector:** `unused-return`
- **Contract:** `FeeCollector` (`src/fees/FeeCollector.sol#L72`)
- **Status:** RESOLVED (commit `d53ba19`)

**Description:**
The `actionType` parameter in `_calculateFee(uint256 amount, uint8 actionType)` was declared but never used in the function body. Fee calculation used a flat basis-point rate regardless of action type.

**Resolution:**
Implemented tiered fee logic that applies different basis-point rates per `ActionType` enum value (dividend: 5 bps, split: 3 bps, merger: 10 bps, etc.).

---

### Informational

| ID | Detector | Location | Description |
|----|----------|----------|-------------|
| I-01 | `pragma` | All contracts | Floating pragma `^0.8.24` used. Consider pinning to `0.8.24` for deterministic builds. |
| I-02 | `dead-code` | `ActionLib.sol#L31` | Internal function `_packActionId()` is defined but never called from any contract. |
| I-03 | `solc-version` | All contracts | Solidity 0.8.24 is not the latest version. Consider upgrading to 0.8.25+ for bug fixes. |
| I-04 | `naming-convention` | `CrossChainNotifier.sol#L45` | Parameter `lzEndpoint_` does not follow mixedCase convention. |
| I-05 | `naming-convention` | `ChainlinkPriceAdapter.sol#L22` | Constant `STALE_PRICE_THRESHOLD` should use `UPPER_CASE_WITH_UNDERSCORES` (already correct, false positive). |
| I-06 | `too-many-digits` | `TimelockController.sol#L14` | Numeric literal `86400` used directly. Consider using a named constant for readability. |
| I-07 | `low-level-calls` | `CrossChainNotifier.sol#L112` | Low-level `.call()` used for LayerZero endpoint interaction. Necessary for interface compatibility. |
| I-08 | `assembly` | `MultiplierMath.sol#L18` | Inline assembly used in `mulDiv()` for gas optimization. Verified against OpenZeppelin reference. |

---

## Contract Analysis Summary

| Contract | File | Lines | Functions | Complexity Score |
|----------|------|-------|-----------|-----------------|
| ActionRegistry | `src/core/ActionRegistry.sol` | 446 | 18 | 34 |
| TimelockController | `src/core/TimelockController.sol` | 90 | 6 | 8 |
| ValidatorManager | `src/core/ValidatorManager.sol` | 162 | 9 | 14 |
| DividendDistributor | `src/executors/DividendDistributor.sol` | 159 | 6 | 12 |
| SplitExecutor | `src/executors/SplitExecutor.sol` | 179 | 7 | 15 |
| MergerHandler | `src/executors/MergerHandler.sol` | 212 | 8 | 22 |
| SpinoffExecutor | `src/executors/SpinoffExecutor.sol` | 108 | 5 | 10 |
| DelistingManager | `src/executors/DelistingManager.sol` | 189 | 7 | 16 |
| TickerMigrator | `src/executors/TickerMigrator.sol` | 159 | 6 | 11 |
| FeeCollector | `src/fees/FeeCollector.sol` | 112 | 5 | 7 |
| AttestationRegistry | `src/verification/AttestationRegistry.sol` | 148 | 6 | 10 |
| ChainlinkPriceAdapter | `src/integrations/ChainlinkPriceAdapter.sol` | 101 | 4 | 6 |
| CrossChainNotifier | `src/integrations/CrossChainNotifier.sol` | 206 | 8 | 18 |
| CrossChainReceiver | `src/integrations/CrossChainReceiver.sol` | 137 | 5 | 9 |
| **Total** | | **2,408** | **100** | **192** |

> Complexity score is calculated as cyclomatic complexity across all functions in each contract.

---

## Recommendations

1. **Pin Solidity pragma to an exact version.** Replace `^0.8.24` with `=0.8.24` across all contracts to ensure reproducible compilation artifacts and eliminate risk of compiler-version drift between environments.

2. **Remove dead code in `ActionLib`.** The unused `_packActionId()` function in `ActionLib.sol` adds surface area without value. Remove it to reduce bytecode size and improve auditability.

3. **Add explicit `MAX_PROOF_LENGTH` revert in `MerkleDistributor`.** While the bound is enforced at the callsite, adding a guard directly in the library function provides defense-in-depth and protects against future callers that may omit the check.

4. **Consider implementing a withdrawal pattern for dividend claims.** The current push-based `safeTransfer` in `claimDividend()` could be supplemented with an emergency pull-based withdrawal to handle edge cases where the payout token blacklists the distributor contract (relevant for USDC/USDT).
