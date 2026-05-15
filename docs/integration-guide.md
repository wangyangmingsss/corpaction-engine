# Integration Guide

## Quick Start

Install the SDK:

```bash
npm install @corpaction/sdk
```

## Basic Usage

```typescript
import { CorpActionClient } from '@corpaction/sdk';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.chain.robinhood.com',
  registryAddress: '0x...',
  chainId: 42161, // Arbitrum
});

// Query pending actions for a token
const pending = await client.getPendingActions({ token: '0xTokenAddress' });

// Subscribe to corporate action events
const unsubscribe = client.onAction('0xTokenAddress', (action) => {
  console.log(`New ${action.type} for ${action.ticker}`);
});
```

## Dividend Claims

```typescript
const tx = await client.claimDividend(intentId, amount, merkleProof, signer);
```

## Event Subscriptions

| Event | Use Case |
|-------|----------|
| ActionProposed | Begin preparing for upcoming corporate action |
| ActionQueued | Action validated, will execute after timelock |
| ActionExecuted | Action completed — update your state |
| ActionCancelled | Action withdrawn — revert preparations |

## Integration Patterns by Protocol Type

- **Lending Protocol:** Listen for DELISTING proposals to begin liquidating collateral
- **Index Fund:** React to dividends (claim and reinvest) and mergers (rebalance)
- **Derivatives:** Adjust strike prices on SplitExecuted events
- **Portfolio Tracker:** Subscribe to all ActionExecuted events for display updates
