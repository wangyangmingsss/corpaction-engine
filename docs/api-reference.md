# API Reference

## Smart Contract Interfaces

### ActionRegistry

| Function | Description |
|----------|-------------|
| `proposeAction(intent, signature)` | Submit a new corporate action intent |
| `validateAction(intentId, signature)` | Add a validator signature to a pending intent |
| `executeAction(intentId)` | Execute a validated and queued intent after timelock |
| `cancelAction(intentId, reason)` | Cancel a pending/failed intent |
| `emergencyPause()` | Trigger emergency pause (any validator) |
| `emergencyResume(signatures)` | Resume after pause (requires supermajority) |
| `getAction(intentId)` | Query an action intent by ID |
| `getActionsByToken(token)` | Get all action IDs for a token |

### DividendDistributor

| Function | Description |
|----------|-------------|
| `claimDividend(intentId, amount, proof)` | Claim dividend with Merkle proof |
| `reclaimExpired(intentId)` | Reclaim unclaimed dividends after deadline |

### Events

| Event | Parameters |
|-------|-----------|
| `ActionProposed` | intentId, actionType, targetToken, ticker |
| `ActionValidated` | intentId, validator, count, required |
| `ActionQueued` | intentId, executionTime |
| `ActionExecuted` | intentId, actionType, targetToken, result |
| `DividendClaimed` | intentId, claimer, amount |
| `SplitExecuted` | intentId, token, oldMultiplier, newMultiplier |

## TypeScript SDK

See `@corpaction/sdk` package documentation and integration guide.
