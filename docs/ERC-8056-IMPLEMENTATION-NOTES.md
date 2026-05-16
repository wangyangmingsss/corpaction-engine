# ERC-8056 Implementation Notes

Technical notes on the implementation decisions, trade-offs, and edge cases encountered while building the CorpAction Engine's stock split infrastructure on top of the ERC-8056 UI multiplier standard.

---

## Reverse Split Fractional Handling (Cash-in-Lieu Mechanism)

### The Problem

In a reverse stock split (e.g., 1:20), holders whose raw balances are not evenly divisible by the split ratio end up with fractional shares. Traditional brokerages handle this by paying cash-in-lieu of fractional shares. On-chain, raw balances do not change during an ERC-8056 split -- only the UI multiplier changes -- but the UI-displayed balance can produce fractional results.

**Example:** A 1:20 reverse split. A holder with 15 raw tokens at a 1e18 multiplier now displays `15 * (1e18 / 20) / 1e18 = 0.75` shares in the UI. The holder is entitled to 0 whole shares plus cash-in-lieu for 0.75 fractional shares.

### Implementation Decision

The `SplitExecutor` supports three fractional handling modes, configured per-action via the `fractionalHandling` field in `SplitParams`:

```solidity
struct SplitParams {
    uint256 numerator;
    uint256 denominator;
    bool    isReverse;
    uint256 expectedNewMultiplier;
    uint256 fractionalHandling; // 0 = round down, 1 = round up, 2 = cash-in-lieu
    address cashInLieuToken;    // USDG address for mode 2
    uint256 cashInLieuPrice;    // price per whole share (18 decimals)
}
```

**Mode 0 (Round Down):** Fractional amounts are silently truncated. Simplest but least fair to holders. Suitable only when fractional value is negligible.

**Mode 1 (Round Up):** Fractional amounts round up to the next whole share. Requires the issuer to cover the cost of the extra fractional shares created. Rarely used on-chain.

**Mode 2 (Cash-in-Lieu):** Fractional amounts are compensated via a Merkle-based USDG distribution. This is the production-recommended mode and mirrors traditional brokerage behavior.

### Cash-in-Lieu Flow

1. `SplitExecutor.execute()` updates the UI multiplier and initializes a `CashInLieuState`
2. Off-chain, the processor computes each holder's fractional entitlement and builds a Merkle tree
3. `setCashInLieuMerkle()` is called to set the Merkle root and claim deadline
4. Holders call `claimCashInLieu()` with their fractional amount and Merkle proof

```solidity
// Payout calculation in claimCashInLieu():
uint256 payout = fractionalAmount * state.pricePerShare / 1e18;
```

### Trade-off

The cash-in-lieu mechanism requires a second transaction (setting the Merkle root) after the split execution, plus pre-funding the `SplitExecutor` with USDG. This adds operational complexity but is necessary for regulatory compliance with US equity standards, where brokerages are required to compensate fractional shares in cash.

---

## Cumulative Multiplier Drift

### The Problem

The `MultiplierMath` library uses integer division, which truncates remainders. When a token undergoes multiple sequential splits, each division operation can lose up to 1 wei of precision. Over many operations, this drift accumulates.

### Measured Drift

```solidity
// MultiplierMath.mulMultiplier for a forward split:
function mulMultiplier(
    uint256 current, uint256 numerator, uint256 denominator
) internal pure returns (uint256) {
    if (denominator == 0) revert DivisionByZero();
    uint256 result = (current * numerator) / denominator;
    if (result == 0) revert Overflow();
    return result;
}
```

**Worst-case drift per operation:** 1 wei (when `current * numerator` is not evenly divisible by `denominator`).

**Example sequence:**

| Operation | Ratio | Multiplier Before | Multiplier After | Drift |
|---|---|---|---|---|
| Initial | 1:1 | 1000000000000000000 | 1000000000000000000 | 0 |
| Forward 3:1 | 3/1 | 1000000000000000000 | 3000000000000000000 | 0 |
| Reverse 1:7 | 1/7 | 3000000000000000000 | 428571428571428571 | -1 wei |
| Forward 5:1 | 5/1 | 428571428571428571 | 2142857142857142855 | -1 wei (cumulative -2) |

### Why This Is Acceptable

At 18 decimal places, 1 wei of drift represents a relative error of approximately `1 / 1e18 = 1e-18`, or 0.0000000000000001%. Even after 100 sequential splits (an extreme scenario no real equity would undergo), the cumulative drift is at most 100 wei, representing a relative error of `1e-16`.

For context, a holder with 1,000,000 tokens would see a UI balance discrepancy of at most `0.0000000001` tokens after 100 splits -- far below any meaningful financial threshold.

### Mitigation

The `SplitExecutor` includes a safety check comparing the calculated multiplier against a pre-computed `expectedNewMultiplier`:

```solidity
// Safety check: verify against pre-calculated value
if (newMultiplier != params.expectedNewMultiplier)
    revert MultiplierMismatch(params.expectedNewMultiplier, newMultiplier);
```

This ensures the off-chain `MultiplierCalculator` and on-chain `MultiplierMath` agree exactly, preventing any divergence between the two systems. The off-chain system uses the same integer arithmetic (not floating point) to pre-compute the expected value.

### Fuzz Testing

The `MultiplierMath.t.sol` fuzz test verifies round-trip properties over 1000+ runs:

```
// Property: mulMultiplier followed by divMultiplier returns to within 1 wei
// of the original value for any valid numerator/denominator pair.
```

---

## Implementation Decisions and Trade-offs

### Decision 1: UI Multiplier vs. Rebase

**Chosen:** UI multiplier (ERC-8056)
**Alternative:** Elastic supply / rebase (like Ampleforth)

| Aspect | UI Multiplier (ERC-8056) | Rebase |
|---|---|---|
| Raw balance changes | No | Yes |
| DeFi compatibility | High (raw balances stable) | Low (breaks lending, AMMs) |
| Gas cost | Single `SSTORE` for multiplier | O(n) balance updates or rebasing logic on every transfer |
| Complexity | Moderate (UI layer must use `balanceOfUI`) | High (accounting complexity) |
| Audit surface | Small (one new function) | Large (every transfer path affected) |

The UI multiplier approach was chosen because it preserves raw ERC-20 compatibility. DeFi protocols that are not split-aware continue to work correctly with raw balances. Only UIs and protocols that specifically need to display post-split values call `balanceOfUI()`.

### Decision 2: Pre-computed Merkle Trees vs. On-chain Enumeration

**Chosen:** Off-chain Merkle tree construction with on-chain proof verification
**Alternative:** On-chain holder enumeration (ERC-20 with `EnumerableSet`)

The Merkle approach scales to any number of holders without increasing on-chain storage or gas costs. The trade-off is that holders must obtain their proof from an off-chain service, but this is a well-understood pattern (used by Uniswap airdrops, Merkle-based distributions).

### Decision 3: Separation of Propose/Validate/Queue/Execute

**Chosen:** 4-phase lifecycle with explicit state transitions
**Alternative:** Single-transaction execution (propose + execute atomically)

The multi-phase approach enables:
- **Validator quorum**: Independent verification before execution
- **Timelock**: Mandatory delay for high-severity actions (24-48h for mergers/delistings)
- **Cancellation**: Any validator can cancel a proposed action before execution
- **Auditability**: Each state transition emits events for monitoring

The cost is additional transactions and latency, but this is appropriate for financial operations where correctness and oversight are more important than speed.

### Decision 4: Severity-Based Quorum Scaling

```
Low severity (ticker change):       2-of-3 validators, 1h timelock
Medium severity (dividend, split):  3-of-5 validators, 6-12h timelock
High severity (merger, delisting):  4-of-5 validators, 24-48h timelock
Reversal (any):                     5-of-5 validators (all must agree)
Emergency pause:                    1-of-N (any single validator)
Emergency resume:                   4-of-5 (supermajority)
```

This design reflects the asymmetric risk profile of different corporate actions. A dividend distribution is relatively low-risk (worst case: incorrect amounts, recoverable via reclaim). A delisting is high-risk (irreversible position liquidation). The quorum and timelock scale accordingly.

---

## Proposed ERC-XXXX Corporate Action Intent Standard

Based on the patterns that emerged during CorpAction Engine development, we propose a future ERC standard for on-chain corporate action intents. This would provide a common interface that any RWA platform could implement, enabling composability across the ecosystem.

### Motivation

Currently, each RWA platform defines its own corporate action data structures and execution patterns. This prevents:
- Cross-platform tooling (portfolio trackers, tax reporting)
- Standardized DeFi integration (automatic collateral adjustment on splits)
- Regulatory reporting automation

### Proposed Interface

```solidity
/// @title IERC-XXXX Corporate Action Intent
/// @notice Standard interface for on-chain corporate action lifecycle management
interface ICorporateActionIntent {

    enum ActionType {
        DIVIDEND,
        FORWARD_SPLIT,
        REVERSE_SPLIT,
        MERGER_CASH,
        MERGER_STOCK,
        MERGER_HYBRID,
        SPINOFF,
        DELISTING,
        TICKER_CHANGE,
        LIQUIDATION
    }

    enum ActionState {
        PROPOSED,
        VALIDATED,
        QUEUED,
        EXECUTING,
        EXECUTED,
        CANCELLED,
        FAILED,
        REVERSED,
        EXPIRED
    }

    struct ActionIntent {
        bytes32  intentId;           // Unique identifier (hash of action parameters)
        ActionType actionType;       // Type of corporate action
        address  targetToken;        // Token contract affected
        string   ticker;             // Human-readable ticker symbol
        bytes    actionParams;       // ABI-encoded type-specific parameters
        uint256  effectiveDate;      // UNIX timestamp of real-world effective date
        uint256  recordDate;         // Snapshot date for holder eligibility
        bytes32  sourceAttestation;  // Link to source verification (filing ID)
        ActionState state;           // Current lifecycle state
        uint256  createdAt;          // Block timestamp of proposal
        uint256  executedAt;         // Block timestamp of execution (0 if not executed)
    }

    /// @notice Emitted when a new corporate action is proposed
    event ActionProposed(
        bytes32 indexed intentId,
        ActionType indexed actionType,
        address indexed targetToken,
        string ticker
    );

    /// @notice Emitted when an action completes execution
    event ActionExecuted(
        bytes32 indexed intentId,
        ActionType indexed actionType,
        address indexed targetToken,
        bytes result
    );

    /// @notice Submit a new corporate action intent
    function proposeAction(
        ActionIntent calldata intent,
        bytes calldata signature
    ) external returns (bytes32 intentId);

    /// @notice Query the current state of an action
    function getAction(bytes32 intentId)
        external view returns (ActionIntent memory);

    /// @notice Get all actions affecting a specific token
    function getActionsByToken(address token)
        external view returns (bytes32[] memory);
}
```

### Design Principles

1. **Type-agnostic parameters**: `actionParams` is `bytes` to allow extensibility without interface changes
2. **Source provenance**: `sourceAttestation` links every action to verifiable real-world data
3. **State machine**: The `ActionState` enum enforces a well-defined lifecycle that never transitions backward
4. **Composability**: The event-driven interface allows any protocol to subscribe and react to corporate actions without direct integration

### Relationship to Existing Standards

| Standard | Relationship |
|---|---|
| ERC-20 | ActionIntents target ERC-20 token contracts |
| ERC-8056 | Split actions use `setUIMultiplier()` from ERC-8056 |
| ISO 20022 (seev.031, seev.036, seev.039) | ActionIntent schema is inspired by ISO 20022 corporate action notification semantics |
| EIP-712 | Source attestations use EIP-712 typed data signing for verifiable provenance |

### Status

This is a concept proposal. A formal ERC submission would require broader community discussion, reference implementation review, and consideration of edge cases across different RWA platforms.

---

## References

- [ERC-8056 Specification](https://eips.ethereum.org/EIPS/eip-8056) -- UI Multiplier for token display adjustment
- [ISO 20022 Securities Events](https://www.iso20022.org/catalogue-messages/additional-content-messages/securities-events) -- Corporate action notification standards
- [EIP-712](https://eips.ethereum.org/EIPS/eip-712) -- Typed structured data hashing and signing
- [OpenZeppelin UUPS Proxy](https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable) -- Upgrade pattern used by all executor contracts
