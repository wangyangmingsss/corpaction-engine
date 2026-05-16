# Test Coverage Report

**Generated:** 2026-05-16
**Test Framework:** Foundry (forge test)
**Solidity Version:** 0.8.24
**Total Tests:** 127 (47 unit, 27 integration, 18 scenario, 14 invariant, 21 fuzz)

## Coverage Summary

| File | Lines | Statements | Branches | Functions |
|------|-------|-----------|----------|-----------|
| `src/core/ActionRegistry.sol` | 96.4% (324/336) | 95.8% (275/287) | 89.2% (66/74) | 100% (18/18) |
| `src/core/TimelockController.sol` | 100% (62/62) | 100% (48/48) | 100% (12/12) | 100% (6/6) |
| `src/core/ValidatorManager.sol` | 97.1% (101/104) | 96.3% (78/81) | 91.7% (22/24) | 100% (9/9) |
| `src/executors/DividendDistributor.sol` | 98.2% (108/110) | 97.6% (82/84) | 93.8% (15/16) | 100% (6/6) |
| `src/executors/SplitExecutor.sol` | 95.6% (109/114) | 94.8% (91/96) | 87.5% (14/16) | 100% (7/7) |
| `src/executors/MergerHandler.sol` | 93.1% (135/145) | 92.4% (110/119) | 85.0% (17/20) | 100% (8/8) |
| `src/executors/SpinoffExecutor.sol` | 97.4% (74/76) | 96.7% (59/61) | 90.0% (9/10) | 100% (5/5) |
| `src/executors/DelistingManager.sol` | 94.7% (125/132) | 93.9% (107/114) | 88.9% (16/18) | 100% (7/7) |
| `src/executors/TickerMigrator.sol` | 96.8% (91/94) | 96.1% (74/77) | 91.7% (11/12) | 100% (6/6) |
| `src/fees/FeeCollector.sol` | 100% (78/78) | 100% (61/61) | 100% (8/8) | 100% (5/5) |
| `src/verification/AttestationRegistry.sol` | 91.2% (93/102) | 90.4% (75/83) | 83.3% (10/12) | 100% (6/6) |
| `src/integrations/ChainlinkPriceAdapter.sol` | 89.7% (61/68) | 88.5% (46/52) | 80.0% (8/10) | 100% (4/4) |
| `src/integrations/CrossChainNotifier.sol` | 88.4% (122/138) | 87.2% (102/117) | 78.6% (11/14) | 87.5% (7/8) |
| `src/integrations/CrossChainReceiver.sol` | 90.1% (82/91) | 89.3% (67/75) | 81.8% (9/11) | 100% (5/5) |

## Overall Coverage: 94.2%

| Metric | Covered | Total | Percentage |
|--------|---------|-------|------------|
| Lines | 1,565 | 1,650 | 94.8% |
| Statements | 1,275 | 1,355 | 94.1% |
| Branches | 228 | 257 | 88.7% |
| Functions | 100 | 101 | 99.0% |

---

## Test Breakdown by Category

| Category | Test Count | Pass | Fail | Skip |
|----------|-----------|------|------|------|
| Unit | 47 | 47 | 0 | 0 |
| Integration | 27 | 27 | 0 | 0 |
| Scenario (real-world) | 18 | 18 | 0 | 0 |
| Invariant | 14 | 14 | 0 | 0 |
| Fuzz (1000 runs each) | 21 | 21 | 0 | 0 |
| **Total** | **127** | **127** | **0** | **0** |

---

## Uncovered Areas

### `ActionRegistry.sol` (Lines 312-324, Branch at L289)

- **Lines 312-324:** Emergency admin override path in `forceCancel()`. This code path requires `msg.sender == emergencyAdmin` and the action to be in a `Validated` state simultaneously. Covered by the `EmergencyPause` integration test but the specific branch where `block.timestamp < action.proposedAt + GRACE_PERIOD` evaluates to `false` is not hit.
- **Branch at L289:** The `else` branch in `_transitionState()` for an invalid state transition from `Cancelled` to `Executed`. This is a defensive guard that should be unreachable under normal operation.

### `ValidatorManager.sol` (Lines 98-102)

- **Lines 98-102:** The `removeValidator()` path where removal causes the active validator count to drop below `minQuorum`. The function reverts with `BelowMinQuorum()`, and while the revert is tested, the internal accounting rollback on lines 100-102 is not fully traced by the coverage tool due to the revert unwinding state.

### `MergerHandler.sol` (Lines 167-178, Branches at L121/L134)

- **Lines 167-178:** Partial conversion path for mergers with mixed cash-and-stock consideration. This requires a specific `MergerTerms.considerationType == MIXED` configuration that is tested in `MergerFlow.t.sol` but the sub-branch where `cashComponent > remainingPool` is not exercised.
- **Branch at L121:** Guard clause for duplicate conversion attempts. Tested via `test_RevertOnDoubleClaim` but branch coverage tool reports partial coverage due to short-circuit evaluation.
- **Branch at L134:** Boundary check `conversionRatio > MAX_RATIO`. Not tested because all scenario tests use realistic ratios well within bounds.

### `SplitExecutor.sol` (Lines 142-148)

- **Lines 142-148:** Fractional share rounding path for reverse splits where `oldShares % splitRatio != 0`. The `ReverseSplitFractional.t.sol` integration test covers the primary rounding case, but the edge case where `fractionalCash == 0` due to price truncation is not covered.

### `AttestationRegistry.sol` (Lines 84-93)

- **Lines 84-93:** Attestation expiry cleanup in `revokeAttestation()`. The branch where an attestation has already expired at the time of revocation is not tested. The function still processes the revocation correctly, but the event emission path for `AttestationExpiredBeforeRevocation` is uncovered.

### `ChainlinkPriceAdapter.sol` (Lines 55-62)

- **Lines 55-62:** Fallback oracle path when the primary Chainlink aggregator returns a stale price (`updatedAt < block.timestamp - STALE_PRICE_THRESHOLD`). Unit tests mock the aggregator to return fresh prices. The stale-price revert is tested, but the fallback-to-secondary-oracle branch (lines 59-62) is not covered because no secondary oracle mock is configured in the test harness.

### `CrossChainNotifier.sol` (Lines 156-170, Function `_retryFailedMessage`)

- **Lines 156-170:** Message retry logic for failed LayerZero sends. This path is triggered by the `retryFailedMessage()` external function, which requires a previously failed message stored in the `failedMessages` mapping. Integration tests do not simulate LayerZero endpoint failures.
- **Function `_retryFailedMessage`:** The only uncovered function across the entire codebase. It is an internal helper called exclusively by the retry path described above.

### `CrossChainReceiver.sol` (Lines 72-80)

- **Lines 72-80:** Message deduplication guard in `lzReceive()`. The branch where a message with an already-processed nonce arrives is not tested because the mock LayerZero endpoint in the test suite does not simulate duplicate delivery.

---

## Gas Benchmarks (Selected Tests)

| Test | Gas Used | Description |
|------|----------|-------------|
| `test_ProposeDividendAction` | 187,432 | Propose a new dividend action with full metadata |
| `test_ValidateWithQuorum` | 243,891 | Three validators attest to reach quorum |
| `test_ClaimDividendMerkle` | 94,217 | Single holder claims via Merkle proof (depth 12) |
| `test_ExecuteStockSplit` | 312,556 | Execute a 4:1 forward split across 50 holders |
| `test_ExecuteReverseSplit` | 298,103 | Execute a 1:10 reverse split with fractional cash-out |
| `test_CrossChainNotify` | 178,644 | Send action notification to 3 destination chains |
| `test_FullDividendLifecycle` | 1,247,883 | End-to-end: propose, validate, timelock, execute, claim |
