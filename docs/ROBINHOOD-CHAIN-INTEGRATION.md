# Robinhood Chain Integration Guide

## Overview

CorpAction Engine is purpose-built for the Robinhood Chain ecosystem, where 500+ US equities are tokenized as ERC-20-compatible tokens. This guide covers the technical requirements, configuration, and step-by-step integration process for deploying and operating the engine on Robinhood Chain.

Robinhood Chain is an Arbitrum-based L2 optimized for tokenized equities. Every tokenized stock on Robinhood Chain must reflect real-world corporate actions -- dividends, splits, mergers, delistings -- in lockstep with traditional markets. CorpAction Engine bridges this gap by ingesting events from SEC EDGAR, DTCC ISO 20022 feeds, and financial data APIs, then executing the corresponding on-chain operations through a validated, timelocked pipeline.

---

## Token Contract Compatibility (ERC-8056 Interface)

Robinhood Chain equity tokens must implement the **ERC-8056** interface to support stock split operations. ERC-8056 extends ERC-20 with a UI multiplier that allows token balances to be displayed correctly after splits without modifying underlying raw balances.

### Required Interface

```solidity
interface IERC8056 is IERC20 {
    /// @notice Returns the current UI multiplier (18 decimals, base = 1e18)
    function uiMultiplier() external view returns (uint256);

    /// @notice Sets a new UI multiplier. Restricted to authorized callers.
    function setUIMultiplier(uint256 newMultiplier) external;

    /// @notice Returns the UI-adjusted balance for an account
    function balanceOfUI(address account) external view returns (uint256);

    /// @notice Converts a raw token amount to its UI-displayed equivalent
    function toUIAmount(uint256 rawAmount) external view returns (uint256);

    /// @notice Converts a UI-displayed amount back to a raw token amount
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);

    /// @notice Emitted when the multiplier is updated (e.g., after a stock split)
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
}
```

### Multiplier Arithmetic

The `MultiplierMath` library uses 18-decimal fixed-point arithmetic:

- **Forward split** (e.g., 10:1): `newMultiplier = current * numerator / denominator`
- **Reverse split** (e.g., 1:20): `newMultiplier = current * denominator / numerator`
- **Base value**: `1e18` (represents a 1:1 multiplier)

Tokens that do not implement `IERC8056` will cause the `SplitExecutor` to revert with `NotERC8056Compliant(address)`.

---

## Permission Requirements

The following roles and permissions must be configured for CorpAction Engine to operate on Robinhood Chain:

| Permission | Contract | Role / Requirement | Purpose |
|---|---|---|---|
| `PROPOSER_ROLE` | ActionRegistry | Granted to ingestion service wallet | Submit new ActionIntent proposals |
| `EXECUTOR_ROLE` | ActionRegistry | Granted to automation/keeper wallet | Trigger `executeAction()` after timelock |
| `DEFAULT_ADMIN_ROLE` | ActionRegistry | Deployer / multisig | Register executors, configure timelocks, set fee collector |
| `UPGRADER_ROLE` | ActionRegistry | Deployer / multisig (72h timelock) | Authorize UUPS proxy upgrades |
| Validator status | ValidatorManager | Each validator node address | Sign proposals, validate actions, trigger emergency pause |
| `setUIMultiplier` | Token (IERC8056) | SplitExecutor contract address | Must be authorized to call `setUIMultiplier()` on each equity token |
| USDC/USDG approval | DividendDistributor | Token issuer / treasury | Must pre-fund distributor with dividend payment tokens |
| Merkle root setter | SplitExecutor | ActionRegistry | Set cash-in-lieu Merkle roots for reverse splits |

---

## Robinhood Chain Testnet Configuration

| Parameter | Value |
|---|---|
| **Chain ID** | `46630` |
| **RPC URL** | `https://rpc.testnet.chain.robinhood.com` |
| **Block Explorer** | `https://explorer.testnet.chain.robinhood.com` |
| **USDG Contract** | `0x7E955252E15c84f5768B83c41a71F9eba181802F` |
| **Network Type** | Arbitrum L2 (Optimistic Rollup) |
| **Gas Token** | ETH (bridged) |
| **Block Time** | ~250ms (Arbitrum L2) |
| **Finality** | Soft finality on L2; ~7 day challenge window for L1 |

### Deployed Contract Addresses (Testnet)

| Contract | Address |
|---|---|
| ValidatorManager | `0xE3fe1728B0Ff8811d1f65Edfe3C9bb58B0a88473` |
| TimelockController | `0x562B3c6302156646f92fc6081734DeeECF4E2e45` |
| AttestationRegistry | `0x9937D10097C189CF0D05dF64F88F975e7977a8eb` |
| ActionRegistry | `0x1D3c8f75A0822c56FC1d7DDd41106a469f3E1A35` |
| FeeCollector | `0x2D5bB4a05Cc741905dcd1F2109349a3c089B66b1` |
| DividendDistributor | `0x6f1fCb522466025Cae1e36306993ddA8Befdd01A` |
| SplitExecutor | `0x710a6aCf4C11eD4E80baCE15C50193328A3c73E4` |
| MergerHandler | `0x33a4306e197444f15E38cb449C9C8a1C227e8bBe` |
| SpinoffExecutor | `0x7622951A02f1Ea1685c87AC31A769B7f822AD544` |
| DelistingManager | `0xb42Ad9213eA7fa316880ee4A6e32a78A073D1C61` |
| TickerMigrator | `0x930812f4deb7ec3E6741b47D7187A70b90368444` |

---

## Integration Steps

### Step 1: Deploy or Connect to Token Contracts

Ensure every tokenized equity on Robinhood Chain implements the `IERC8056` interface. If you are the token issuer:

```solidity
// Grant SplitExecutor permission to update the UI multiplier
token.grantRole(MULTIPLIER_ADMIN_ROLE, splitExecutorAddress);
```

If you are integrating with existing Robinhood-issued tokens, confirm ERC-8056 compliance by calling:

```typescript
const multiplier = await tokenContract.uiMultiplier();
// Should return 1000000000000000000 (1e18) for a token with no prior splits
```

### Step 2: Configure the SDK Client

```typescript
import { CorpActionClient } from '@corpaction/sdk';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
  registryAddress: '0x1D3c8f75A0822c56FC1d7DDd41106a469f3E1A35',
  dividendDistributorAddress: '0x6f1fCb522466025Cae1e36306993ddA8Befdd01A',
  splitExecutorAddress: '0x710a6aCf4C11eD4E80baCE15C50193328A3c73E4',
  mergerHandlerAddress: '0x33a4306e197444f15E38cb449C9C8a1C227e8bBe',
  delistingManagerAddress: '0xb42Ad9213eA7fa316880ee4A6e32a78A073D1C61',
  spinoffExecutorAddress: '0x7622951A02f1Ea1685c87AC31A769B7f822AD544',
  tickerMigratorAddress: '0x930812f4deb7ec3E6741b47D7187A70b90368444',
  chainId: 46630,
});
```

### Step 3: Subscribe to Corporate Action Events

Register event listeners for the corporate actions relevant to your protocol:

```typescript
// React to all actions on a specific token
client.onAction('0xAAPL_TOKEN_ADDRESS', (action) => {
  const params = client.decodeActionParams(action.type, action.rawParams);
  console.log(`Corporate action: ${action.type} for ${action.ticker}`, params);
});

// Granular subscriptions
client.onDividendClaimed((intentId, claimer, amount) => {
  // Update internal accounting
});

client.onSplitExecuted((intentId, token, oldMultiplier, newMultiplier) => {
  // Adjust derivative strike prices, rebalance positions
});

client.onDelistingInitiated((intentId, token, finalPrice) => {
  // Begin liquidating collateral positions
});
```

### Step 4: Implement Claim Flows

For dividend and cash-in-lieu distributions, integrate the Merkle-proof claim flow:

```typescript
// Claim a dividend
const tx = await client.claimDividend(intentId, amount, merkleProof, signer);
await tx.wait();

// Claim on behalf of another holder (batch proxy)
await client.claimOnBehalf(intentId, holderAddress, amount, proof, signer);

// Check strike price adjustment after a split (for derivatives protocols)
const adjustment = await client.getStrikePriceAdjustment(intentId);
```

---

## Gas Cost Analysis

Estimated gas costs for key operations on Robinhood Chain (Arbitrum L2). Actual costs depend on calldata size, Merkle proof depth, and L1 posting fees.

| Operation | Function | Estimated Gas (L2) | Notes |
|---|---|---|---|
| Propose Action | `proposeAction()` | ~180,000 | Includes signature recovery, state initialization, quorum check |
| Validate Action | `validateAction()` | ~95,000 | Signature recovery + validation count increment |
| Queue Action | `queueAction()` | ~55,000 | State transition + timelock calculation |
| Execute Action | `executeAction()` | ~250,000 - 500,000 | Varies by executor; includes fee collection and attestation check |
| Execute Dividend | `execute()` (DividendDistributor) | ~150,000 | Merkle root storage, state initialization |
| Execute Split | `execute()` (SplitExecutor) | ~120,000 | Multiplier calculation + `setUIMultiplier()` call |
| Claim Dividend | `claimDividend()` | ~85,000 | Merkle proof verification + USDC transfer |
| Claim Cash-in-Lieu | `claimCashInLieu()` | ~90,000 | Merkle proof verification + payout calculation + transfer |
| Emergency Pause | `emergencyPause()` | ~45,000 | Single validator, immediate effect |
| Emergency Resume | `emergencyResume()` | ~120,000 | Multi-signature verification (supermajority) |
| Cancel Action | `cancelAction()` | ~40,000 | State transition only |
| Reverse Action | `reverseAction()` | ~150,000 | All-validator signature verification loop |

### Cost Estimation at Current L2 Gas Prices

At a typical Robinhood Chain gas price of 0.01 gwei:

| Scenario | Total Gas | Estimated Cost (ETH) | Estimated Cost (USD @ $3,500/ETH) |
|---|---|---|---|
| Full dividend lifecycle (propose + validate + queue + execute + 1000 claims) | ~85,430,000 | ~0.000854 | ~$2.99 |
| Stock split (propose through execute) | ~580,000 | ~0.0000058 | ~$0.02 |
| Merger with 500 holder elections | ~25,300,000 | ~0.000253 | ~$0.89 |

> **Note:** L1 data posting costs (calldata fees) are additional and depend on Arbitrum batch compression. These estimates reflect L2 execution gas only.

---

## Additional Resources

- [Architecture Documentation](./architecture.md)
- [Security Model](./security-model.md)
- [API Reference](./api-reference.md)
- [General Integration Guide](./integration-guide.md)
