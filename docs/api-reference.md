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
| `ActionCancelled` | intentId, reason |
| `ActionFailed` | intentId, reason |
| `DividendClaimed` | intentId, claimer, amount |
| `SplitExecuted` | intentId, token, oldMultiplier, newMultiplier, numerator, denominator, isReverse |
| `MergerExecuted` | intentId, targetToken, acquirerToken |
| `DelistingInitiated` | intentId, token, finalPrice |
| `SpinoffDistributed` | intentId, parentToken, newToken |
| `TickerMigrated` | intentId, oldTicker, newTicker |
| `EmergencyPaused` | caller, reason |
| `EmergencyResumed` | caller, reason |

---

## TypeScript SDK (`@corpaction/sdk`)

### Installation

```bash
npm install @corpaction/sdk
```

### CorpActionClient Constructor

```typescript
import { CorpActionClient } from '@corpaction/sdk';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
  registryAddress: '0x1234...abcd',
  chainId: 46630,

  // Optional: required only for methods that interact with these contracts
  dividendDistributorAddress: '0x...',
  splitExecutorAddress: '0x...',
  mergerHandlerAddress: '0x...',
  delistingManagerAddress: '0x...',
  spinoffExecutorAddress: '0x...',
  tickerMigratorAddress: '0x...',

  // Optional: retry configuration for RPC calls
  maxRetries: 3,           // default: 3
  retryBaseDelayMs: 1000,  // default: 1000 (exponential backoff)
});
```

See [`CorpActionClientConfig`](#corpactionclientconfig) for the full config type.

### Query Methods

#### `getAction(intentId: string): Promise<ActionIntent>`

Fetch a single corporate action by its intent ID.

```typescript
const action = await client.getAction('0xabc123...');
console.log(action.ticker, ActionType[action.actionType], ActionState[action.state]);
```

#### `getActionsByToken(tokenAddress: string): Promise<string[]>`

Return all intent IDs associated with a token address.

```typescript
const intentIds = await client.getActionsByToken('0xTokenAddress...');
```

#### `getPendingActions(filter?: PendingActionFilter): Promise<ActionIntent[]>`

Return actions that are still pending (state <= QUEUED) for a given token. Optionally filter by action type or state. Requires `filter.token` to be set; returns an empty array otherwise.

```typescript
import { ActionType, ActionState } from '@corpaction/sdk';

const pending = await client.getPendingActions({
  token: '0xTokenAddress...',
  actionType: ActionType.DIVIDEND,
  state: ActionState.VALIDATED,
});
```

#### `getValidationCount(intentId: string): Promise<number>`

Return the number of validator signatures collected for an intent.

```typescript
const count = await client.getValidationCount('0xabc123...');
```

#### `getExecutionTime(intentId: string): Promise<number>`

Return the scheduled execution timestamp (Unix seconds) for a queued intent.

```typescript
const execTime = await client.getExecutionTime('0xabc123...');
const date = new Date(execTime * 1000);
```

### Action Methods

#### `claimDividend(intentId, amount, merkleProof, signer): Promise<TransactionReceipt>`

Claim a dividend payout using a Merkle proof. Requires `dividendDistributorAddress` in config.

| Parameter | Type | Description |
|-----------|------|-------------|
| `intentId` | `string` | The intent ID of the dividend action |
| `amount` | `bigint` | The claimable amount in the payment token's smallest unit |
| `merkleProof` | `string[]` | Array of Merkle proof hashes |
| `signer` | `ethers.Signer` | Wallet signer to submit the transaction |

```typescript
import { ethers } from 'ethers';

const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

const receipt = await client.claimDividend(
  '0xIntentId...',
  1000000n,  // e.g. 1 USDC (6 decimals)
  ['0xproof1...', '0xproof2...'],
  signer
);
console.log('Claimed in tx:', receipt.hash);
```

#### `batchClaimDividends(claims, signer): Promise<TransactionReceipt[]>`

Claim dividends across multiple intents in sequence. Each claim is submitted as a separate transaction with automatic retry and exponential backoff.

| Parameter | Type | Description |
|-----------|------|-------------|
| `claims` | `Array<{ intentId: string; amount: bigint; merkleProof: string[] }>` | Array of claim parameters |
| `signer` | `ethers.Signer` | Wallet signer |

```typescript
const receipts = await client.batchClaimDividends(
  [
    { intentId: '0xIntent1...', amount: 500000n, merkleProof: ['0x...'] },
    { intentId: '0xIntent2...', amount: 750000n, merkleProof: ['0x...'] },
  ],
  signer
);
```

#### `hasClaimed(intentId: string, address: string): Promise<boolean>`

Check whether a given address has already claimed a dividend for an intent. Returns `false` if the `dividendDistributorAddress` is not configured.

```typescript
const alreadyClaimed = await client.hasClaimed('0xIntentId...', '0xUserAddress...');
```

#### `verifyAttestation(intentId, attestationRegistryAddress): Promise<boolean>`

Check whether at least one verified source attestation exists for a given intent.

| Parameter | Type | Description |
|-----------|------|-------------|
| `intentId` | `string` | The intent ID to verify |
| `attestationRegistryAddress` | `string` | Address of the attestation registry contract |

```typescript
const verified = await client.verifyAttestation('0xIntentId...', '0xAttestationRegistry...');
```

#### `getStrikePriceAdjustment(intentId: string): Promise<{ numerator: bigint; denominator: bigint; adjustmentFactor: number }>`

Compute the strike price adjustment factor for a stock split by reading the `SplitExecuted` event from the chain. Requires `splitExecutorAddress` in config.

```typescript
const adj = await client.getStrikePriceAdjustment('0xSplitIntentId...');
console.log(`Adjustment: ${adj.numerator}/${adj.denominator} = ${adj.adjustmentFactor}`);
```

### Subscription Methods

All subscription methods return an **unsubscribe function** `() => void`. Call it to stop listening.

#### `onAction(tokenAddress, callback): () => void`

Listen for `ActionExecuted` events filtered to a specific token. The callback receives an `ActionEvent`.

```typescript
const unsub = client.onAction('0xTokenAddress...', (event) => {
  console.log(`${event.type} executed for ${event.ticker} at ${event.timestamp}`);
});

// Later: stop listening
unsub();
```

#### `onActionProposed(callback): () => void`

Fires when any new action intent is proposed.

```typescript
const unsub = client.onActionProposed(({ intentId, actionType, targetToken, ticker }) => {
  console.log(`New proposal: ${ticker} (type ${actionType})`);
});
```

#### `onActionValidated(callback): () => void`

Fires when a validator adds a signature to an intent.

```typescript
const unsub = client.onActionValidated(({ intentId, validator, count, required }) => {
  console.log(`Validation ${count}/${required} by ${validator}`);
});
```

#### `onActionQueued(callback): () => void`

Fires when an intent reaches the required validations and enters the timelock queue.

```typescript
const unsub = client.onActionQueued(({ intentId, executionTime }) => {
  console.log(`Queued for execution at ${new Date(executionTime * 1000).toISOString()}`);
});
```

#### `onActionCancelled(callback): () => void`

Fires when an intent is cancelled.

```typescript
const unsub = client.onActionCancelled(({ intentId, reason }) => {
  console.log(`Cancelled: ${reason}`);
});
```

#### `onActionFailed(callback): () => void`

Fires when an intent execution fails.

```typescript
const unsub = client.onActionFailed(({ intentId, reason }) => {
  console.log(`Failed: ${reason}`);
});
```

#### `onEmergencyPaused(callback): () => void`

Fires when emergency pause is triggered.

```typescript
const unsub = client.onEmergencyPaused(({ caller, reason }) => {
  console.log(`PAUSED by ${caller}: ${reason}`);
});
```

#### `onEmergencyResumed(callback): () => void`

Fires when the system resumes after an emergency pause.

#### `onDividendClaimed(callback): () => void`

Listen for dividend claim events. Requires `dividendDistributorAddress` in config.

```typescript
const unsub = client.onDividendClaimed(({ intentId, claimer, amount }) => {
  console.log(`${claimer} claimed ${amount} for intent ${intentId}`);
});
```

#### `onSplitExecuted(callback): () => void`

Listen for stock split execution events. Requires `splitExecutorAddress` in config.

```typescript
const unsub = client.onSplitExecuted(({ intentId, token, oldMultiplier, newMultiplier, numerator, denominator, isReverse }) => {
  console.log(`Split ${numerator}:${denominator} (reverse=${isReverse})`);
});
```

#### `onMergerExecuted(callback): () => void`

Listen for merger execution events. Requires `mergerHandlerAddress` in config.

```typescript
const unsub = client.onMergerExecuted(({ intentId, targetToken, acquirerToken }) => {
  console.log(`Merger: ${targetToken} -> ${acquirerToken}`);
});
```

#### `onDelistingInitiated(callback): () => void`

Listen for delisting initiation events. Requires `delistingManagerAddress` in config.

```typescript
const unsub = client.onDelistingInitiated(({ intentId, token, finalPrice }) => {
  console.log(`Delisting ${token} at price ${finalPrice}`);
});
```

#### `onSpinoffDistributed(callback): () => void`

Listen for spinoff distribution events. Requires `spinoffExecutorAddress` in config.

```typescript
const unsub = client.onSpinoffDistributed(({ intentId, parentToken, newToken }) => {
  console.log(`Spinoff: ${parentToken} -> ${newToken}`);
});
```

#### `onTickerMigrated(callback): () => void`

Listen for ticker migration events. Requires `tickerMigratorAddress` in config.

```typescript
const unsub = client.onTickerMigrated(({ intentId, oldTicker, newTicker }) => {
  console.log(`Ticker changed: ${oldTicker} -> ${newTicker}`);
});
```

### Parameter Decoding

#### `decodeActionParams(actionType: ActionType, rawParams: string): DecodedActionParams`

Decode the ABI-encoded `actionParams` field from an `ActionIntent` into a typed object. The return type depends on the `actionType`:

| ActionType | Return Type |
|------------|-------------|
| `DIVIDEND` | `DividendParams` |
| `FORWARD_SPLIT`, `REVERSE_SPLIT` | `SplitParams` |
| `MERGER_CASH`, `MERGER_STOCK`, `MERGER_HYBRID` | `MergerParams` |
| `DELISTING` | `DelistingParams` |
| `SPINOFF` | `SpinoffParams` |
| `TICKER_CHANGE` | `TickerChangeParams` |
| `LIQUIDATION` | `LiquidationParams` |

```typescript
const action = await client.getAction('0xIntentId...');
const params = client.decodeActionParams(action.actionType, action.actionParams);

if (action.actionType === ActionType.DIVIDEND) {
  const div = params as DividendParams;
  console.log(`Amount per share: ${div.amountPerShare}, deadline: ${div.claimDeadline}`);
}
```

### Type Definitions

#### `ActionType` (enum)

```typescript
enum ActionType {
  DIVIDEND = 0,
  FORWARD_SPLIT = 1,
  REVERSE_SPLIT = 2,
  MERGER_CASH = 3,
  MERGER_STOCK = 4,
  MERGER_HYBRID = 5,
  SPINOFF = 6,
  DELISTING = 7,
  LIQUIDATION = 8,
  TICKER_CHANGE = 9,
}
```

#### `ActionState` (enum)

```typescript
enum ActionState {
  PROPOSED = 0,
  VALIDATED = 1,
  QUEUED = 2,
  EXECUTING = 3,
  EXECUTED = 4,
  FAILED = 5,
  CANCELLED = 6,
  REVERSED = 7,
  PAUSED = 8,
  EXPIRED = 9,
}
```

#### `ActionIntent`

```typescript
interface ActionIntent {
  intentId: string;
  actionType: ActionType;
  targetToken: string;
  ticker: string;
  isin: string;
  recordDate: bigint;
  exDate: bigint;
  effectiveDate: bigint;
  actionParams: string;       // ABI-encoded, use decodeActionParams() to decode
  sourceAttestation: string;
  state: ActionState;
  createdAt: bigint;
  executedAt: bigint;
}
```

#### `ActionEvent`

```typescript
interface ActionEvent {
  intentId: string;
  type: string;          // Human-readable ActionType name (e.g. "DIVIDEND")
  ticker: string;
  targetToken: string;
  params: Record<string, unknown>;
  timestamp: number;     // Unix seconds
}
```

#### `PendingActionFilter`

```typescript
interface PendingActionFilter {
  token?: string;
  actionType?: ActionType;
  state?: ActionState;
}
```

#### `CorpActionClientConfig`

```typescript
interface CorpActionClientConfig {
  rpcUrl: string;                        // JSON-RPC endpoint URL
  registryAddress: string;               // ActionRegistry contract address
  chainId: number;                       // Chain ID (e.g. 46630)
  dividendDistributorAddress?: string;   // Required for dividend claim methods
  splitExecutorAddress?: string;         // Required for split subscriptions
  mergerHandlerAddress?: string;         // Required for merger subscriptions
  delistingManagerAddress?: string;      // Required for delisting subscriptions
  spinoffExecutorAddress?: string;       // Required for spinoff subscriptions
  tickerMigratorAddress?: string;        // Required for ticker migration subscriptions
  maxRetries?: number;                   // Max RPC retry attempts (default: 3)
  retryBaseDelayMs?: number;             // Base delay in ms for exponential backoff (default: 1000)
}
```

#### Action Parameter Types

**`DividendParams`**

| Field | Type | Description |
|-------|------|-------------|
| `paymentToken` | `string` | Address of the ERC-20 token used for payment |
| `totalAmount` | `bigint` | Total dividend pool size |
| `amountPerShare` | `bigint` | Dividend amount per share |
| `merkleRoot` | `string` | Merkle root for claim verification |
| `snapshotBlock` | `bigint` | Block number of the holder snapshot |
| `claimDeadline` | `bigint` | Unix timestamp after which claims expire |
| `withholding` | `boolean` | Whether tax withholding applies |
| `withholdingBps` | `bigint` | Withholding rate in basis points |

**`SplitParams`**

| Field | Type | Description |
|-------|------|-------------|
| `numerator` | `bigint` | Split ratio numerator |
| `denominator` | `bigint` | Split ratio denominator |
| `isReverse` | `boolean` | True for reverse splits |
| `expectedNewMultiplier` | `bigint` | Expected multiplier after split |
| `fractionalHandling` | `bigint` | Strategy for fractional shares |
| `cashInLieuToken` | `string` | Token address for cash-in-lieu payments |
| `cashInLieuPrice` | `bigint` | Price per fractional share in cash-in-lieu |

**`MergerParams`**

| Field | Type | Description |
|-------|------|-------------|
| `mergerType` | `number` | 0 = cash, 1 = stock, 2 = hybrid |
| `acquiringToken` | `string` | Address of the acquiring company's token |
| `exchangeRatioNum` | `bigint` | Exchange ratio numerator |
| `exchangeRatioDen` | `bigint` | Exchange ratio denominator |
| `cashPerShare` | `bigint` | Cash component per share |
| `cashToken` | `string` | Token used for cash component |
| `electionDeadline` | `bigint` | Deadline for shareholder election |
| `hasElection` | `boolean` | Whether shareholders can elect cash vs stock |
| `prorationFactor` | `bigint` | Proration factor if oversubscribed |
| `merkleRoot` | `string` | Merkle root for claim verification |
| `totalCashPool` | `bigint` | Total cash pool for the merger |

**`DelistingParams`**

| Field | Type | Description |
|-------|------|-------------|
| `announcementTime` | `bigint` | Announcement timestamp |
| `sellOnlyTime` | `bigint` | When trading switches to sell-only |
| `priceLockTime` | `bigint` | When the final price is locked |
| `finalPrice` | `bigint` | Final delisting price |
| `settlementToken` | `string` | Token used for settlement |
| `merkleRoot` | `string` | Merkle root for claim verification |
| `totalPool` | `bigint` | Total settlement pool |
| `claimDeadline` | `bigint` | Claim expiration timestamp |

**`SpinoffParams`**

| Field | Type | Description |
|-------|------|-------------|
| `newToken` | `string` | Address of the spun-off token |
| `distributionRatioNum` | `bigint` | Distribution ratio numerator |
| `distributionRatioDen` | `bigint` | Distribution ratio denominator |
| `merkleRoot` | `string` | Merkle root for claim verification |
| `snapshotBlock` | `bigint` | Block number of the holder snapshot |
| `claimDeadline` | `bigint` | Claim expiration timestamp |

**`TickerChangeParams`**

| Field | Type | Description |
|-------|------|-------------|
| `newToken` | `string` | Address of the new token contract |
| `newTicker` | `string` | New ticker symbol |
| `newName` | `string` | New token name |
| `merkleRoot` | `string` | Merkle root for claim verification |
| `snapshotBlock` | `bigint` | Block number of the holder snapshot |
| `claimDeadline` | `bigint` | Claim expiration timestamp |

**`LiquidationParams`**

| Field | Type | Description |
|-------|------|-------------|
| `announcementTime` | `bigint` | Announcement timestamp |
| `sellOnlyTime` | `bigint` | When trading switches to sell-only |
| `priceLockTime` | `bigint` | When the final price is locked |
| `finalPrice` | `bigint` | Final liquidation price |
| `settlementToken` | `string` | Token used for settlement |
| `merkleRoot` | `string` | Merkle root for claim verification |
| `totalPool` | `bigint` | Total settlement pool |
| `claimDeadline` | `bigint` | Claim expiration timestamp |

**`DecodedActionParams`** (union type)

```typescript
type DecodedActionParams =
  | DividendParams
  | SplitParams
  | MergerParams
  | DelistingParams
  | SpinoffParams
  | TickerChangeParams
  | LiquidationParams;
```

### Error Types

#### `CorpActionErrorType` (enum)

```typescript
enum CorpActionErrorType {
  RPC_ERROR = 'RPC_ERROR',             // Network or RPC provider failure
  CONTRACT_ERROR = 'CONTRACT_ERROR',   // Smart contract revert or unexpected response
  INVALID_PARAMS = 'INVALID_PARAMS',   // Invalid parameters passed to SDK methods
  NOT_CONFIGURED = 'NOT_CONFIGURED',   // Required contract address missing from config
  TIMEOUT = 'TIMEOUT',                 // Operation timed out
  UNKNOWN = 'UNKNOWN',                 // Unclassified error
}
```

#### `CorpActionError`

Base error class for all SDK errors.

```typescript
class CorpActionError extends Error {
  readonly errorType: CorpActionErrorType;
  readonly details?: Record<string, unknown>;
}
```

#### `RPCError`

Thrown when an RPC call fails after exhausting all retry attempts. Extends `CorpActionError` with `errorType = RPC_ERROR`.

```typescript
class RPCError extends CorpActionError {}
```

#### `ContractError`

Thrown when a smart contract call reverts or returns unexpected data. Extends `CorpActionError` with `errorType = CONTRACT_ERROR`.

```typescript
class ContractError extends CorpActionError {}
```

**Error handling example:**

```typescript
import { CorpActionError, CorpActionErrorType, RPCError } from '@corpaction/sdk';

try {
  const action = await client.getAction('0xInvalidId...');
} catch (error) {
  if (error instanceof RPCError) {
    console.error('Network issue, retries exhausted:', error.details);
  } else if (error instanceof CorpActionError) {
    switch (error.errorType) {
      case CorpActionErrorType.NOT_CONFIGURED:
        console.error('Missing contract address in config');
        break;
      case CorpActionErrorType.INVALID_PARAMS:
        console.error('Bad parameters:', error.message);
        break;
      default:
        console.error('SDK error:', error.message);
    }
  }
}
```

### Code Examples

#### Monitor all corporate actions for a token

```typescript
import { CorpActionClient, ActionType } from '@corpaction/sdk';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
  registryAddress: '0xRegistryAddress...',
  chainId: 46630,
  dividendDistributorAddress: '0xDividendDistributor...',
  splitExecutorAddress: '0xSplitExecutor...',
});

const TOKEN = '0xMyTokenAddress...';

// Subscribe to executed actions
const unsubAction = client.onAction(TOKEN, (event) => {
  console.log(`[${event.type}] ${event.ticker} at ${event.timestamp}`);
});

// Subscribe to new proposals
const unsubProposed = client.onActionProposed(({ ticker, actionType }) => {
  console.log(`New proposal for ${ticker}: ${ActionType[actionType]}`);
});

// Cleanup on shutdown
process.on('SIGINT', () => {
  unsubAction();
  unsubProposed();
});
```

#### Claim a dividend

```typescript
import { CorpActionClient } from '@corpaction/sdk';
import { ethers } from 'ethers';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
  registryAddress: '0xRegistryAddress...',
  chainId: 46630,
  dividendDistributorAddress: '0xDividendDistributor...',
});

const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();
const userAddress = await signer.getAddress();

const intentId = '0xDividendIntentId...';

// Check if already claimed
if (await client.hasClaimed(intentId, userAddress)) {
  console.log('Already claimed');
} else {
  const receipt = await client.claimDividend(
    intentId,
    1000000n,
    ['0xproofHash1...', '0xproofHash2...'],
    signer
  );
  console.log('Claimed in tx:', receipt.hash);
}
```

#### Decode action parameters and display details

```typescript
import { CorpActionClient, ActionType, DividendParams, SplitParams } from '@corpaction/sdk';

const client = new CorpActionClient({ /* ... */ });

const action = await client.getAction('0xIntentId...');
const params = client.decodeActionParams(action.actionType, action.actionParams);

switch (action.actionType) {
  case ActionType.DIVIDEND: {
    const div = params as DividendParams;
    console.log(`Dividend: ${div.amountPerShare} per share`);
    console.log(`Claim by: ${new Date(Number(div.claimDeadline) * 1000).toISOString()}`);
    break;
  }
  case ActionType.FORWARD_SPLIT:
  case ActionType.REVERSE_SPLIT: {
    const split = params as SplitParams;
    console.log(`Split: ${split.numerator}:${split.denominator} (reverse=${split.isReverse})`);
    break;
  }
}
```

#### Track validation progress

```typescript
const client = new CorpActionClient({ /* ... */ });

const intentId = '0xPendingIntentId...';

// Check current validation count
const count = await client.getValidationCount(intentId);
console.log(`Current validations: ${count}`);

// Listen for new validations
const unsub = client.onActionValidated(({ intentId: id, count, required }) => {
  if (id === intentId) {
    console.log(`Validation progress: ${count}/${required}`);
  }
});
```

#### Verify source attestation before acting on an action

```typescript
const client = new CorpActionClient({ /* ... */ });

const intentId = '0xIntentId...';
const attestationRegistry = '0xAttestationRegistryAddress...';

const isVerified = await client.verifyAttestation(intentId, attestationRegistry);
if (isVerified) {
  console.log('Action has at least one verified source attestation');
} else {
  console.log('WARNING: No verified attestation found for this action');
}
```
