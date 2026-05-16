# CorpAction Engine

**Tokenized Equity Corporate Action Automation Engine for Robinhood Chain / Arbitrum**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Solidity](https://img.shields.io/badge/solidity-0.8.24-363636.svg)
![Foundry](https://img.shields.io/badge/built%20with-Foundry-FFDB1C.svg)
![Tests](https://img.shields.io/badge/tests-100%2B%20passing-brightgreen.svg)
![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen.svg)

## The Problem

Robinhood Chain tokenizes 500+ US equities. But real stocks experience corporate actions daily: dividends, splits, mergers, spin-offs, delistings. Every single one needs its on-chain counterpart to execute in sync, or the token diverges from reality.

Today, **every RWA platform handles this manually**. There is no open, composable, standardized infrastructure for tokenized equity lifecycle management.

## The Solution

CorpAction Engine is a **Corporate Action Oracle + Execution Engine** that:

1. **Monitors** SEC EDGAR, DTCC ISO 20022, and financial data APIs for corporate action events
2. **Normalizes** events into on-chain Action Intents (ISO 20022-inspired schema)
3. **Executes** on Robinhood Chain: USDC dividends, ERC-8056 splits, token mergers, delisting freezes
4. **Attests** every action with verifiable source provenance + multi-sig confirmation

## Architecture

```
SEC EDGAR / DTCC / Data APIs  -->  Ingestion Layer  -->  Normalization Engine
                                                                |
                                                         ActionIntent
                                                                |
                                                     Validator Quorum (M-of-N)
                                                                |
                                                     On-Chain Execution
                                                  (ActionRegistry + Executors)
                                                                |
                                                     Attestation Registry
```

### System Layers

| Layer | Components | Technology |
|-------|-----------|------------|
| Data Ingestion | SEC EDGAR Monitor (+ RSS fallback), DTCC ISO 20022 Parser, EOD Historical, Polygon.io, Alpha Vantage, Bloomberg/Refinitiv (enterprise) | TypeScript, Redis |
| Normalization | Event Classifier (8-K item-level), Event Deduplicator (ISIN fallback, multi-source confidence), ActionIntent Builder (ERC-8056 multiplier pre-calc) | TypeScript, Rule Engine |
| On-Chain Execution | ActionRegistry (with fee/attestation integration), 6 Executor Contracts, AttestationRegistry | Solidity 0.8.24, Foundry, OpenZeppelin 5.x |
| Attestation & Governance | Multi-sig Validator (on-chain event listening, coordination), Source Attestation, Audit Trail | Solidity, ECDSA, EIP-712 |
| Monitoring & Alerting | Prometheus (10 alert rules), Grafana dashboards, structured JSON logging, /metrics endpoints | Prometheus, Grafana |

## Supported Corporate Actions

| Action | On-Chain Execution | Standard |
|--------|-------------------|----------|
| Dividend | Merkle-based USDC distribution with withholding tax support | ISO 20022 seev.031 |
| Stock Split (Forward) | ERC-8056 UI multiplier update | ERC-8056 |
| Stock Split (Reverse) | ERC-8056 + Merkle-based cash-in-lieu for fractional shares | ERC-8056 |
| Merger (Cash) | Position liquidation + USDC payout with proration | ISO 20022 seev.036 |
| Merger (Stock) | Token swap at exchange ratio with election mechanism | ISO 20022 seev.036 |
| Merger (Hybrid) | Combined cash + stock with holder election | ISO 20022 seev.036 |
| Spin-off | New token deployment + Merkle distribution | ISO 20022 seev.031 |
| Delisting | 5-phase freeze + forced liquidation with dispute/rollback | ISO 20022 seev.039 |
| Ticker Change | Token migration with symbol update | N/A |

## Smart Contracts

| Contract | Purpose | Key Features |
|----------|---------|-------------|
| `ActionRegistry` | Central lifecycle registry (propose -> validate -> queue -> execute) | Fee/attestation integration, reverseAction(), TimelockController delegation, token mapping, queue expiration, intent TTL |
| `ValidatorManager` | Validator set, signature verification, severity-based quorum | Dynamic validator management, EIP-191 signatures |
| `TimelockController` | Mandatory delays per action type (1h-48h) | Configurable per action type, severity-based scaling, queue TTL expiration |
| `DividendDistributor` | Merkle-tree USDC pull distribution | Withholding tax (basis points), snapshotBlock tracking, claim deadlines |
| `SplitExecutor` | ERC-8056 `setUIMultiplier` for splits | Cash-in-lieu for reverse split fractionals via Merkle claims |
| `MergerHandler` | Cash-only, stock-for-stock, hybrid mergers | Election mechanism, proration factor, cash pool validation, finalize |
| `SpinoffExecutor` | New token distribution via Merkle claims | Claim deadlines, proof verification |
| `DelistingManager` | 5-phase delisting process | Each phase transitions individually, dispute/rollback, claim deadline |
| `TickerMigrator` | Symbol/address migration with balance snapshot | Old token freeze, ActionRegistry token mapping update, Merkle-based claim |
| `AttestationRegistry` | Cryptographic source attestation with EIP-712 typed data signing | Submit, verify, query attestations per intent |
| `FeeCollector` | Per-action fee calculation and collection | Configurable schedule with caps |

## Testing

Comprehensive testing suite with 100+ tests across 5 categories:

### Unit Tests (12 files)
Every contract has dedicated unit tests covering happy paths, revert conditions, edge cases, access control, and state transitions:
- `ActionRegistry.t.sol` - Proposal, validation, execution, cancellation, reversal, emergency, timelock, TTL, routing, permissions
- `ValidatorManager.t.sol` - Add/remove validators, quorum, signatures, super majority
- `TimelockController.t.sol` - Default timelocks per action type, configuration, validation
- `DividendDistributor.t.sol` - Execute, claim, withholding tax, double-claim, expiry, reclaim
- `SplitExecutor.t.sol` - Forward/reverse splits, cash-in-lieu, multiplier verification
- `MergerHandler.t.sol` - All 3 merger types, elections, proration, finalization
- `DelistingManager.t.sol` - All 5 phases, claims, disputes, rollback
- `SpinoffExecutor.t.sol` - Execute, claim, proof verification, deadlines
- `TickerMigrator.t.sol` - Execute, claim migration, proof verification
- `FeeCollector.t.sol` - Fee calculation per type, caps, collection, permissions
- `AttestationRegistry.t.sol` - Submit, verify, query, access control
- `MultiplierMath.t.sol` - Arithmetic operations, rounding, edge cases

### Integration Tests (10 files)
End-to-end scenarios exercising the full pipeline:
- **Dividend Flow** - Full propose -> validate -> execute -> Merkle claim pipeline
- **Stock Split** - 4:1 forward split -> multiplier verification -> balanceOfUI
- **Reverse Split + Fractional** - 1:10 reverse split -> cash-in-lieu claims
- **Merger Flow** - Stock-for-stock -> freeze -> distribute -> exchange ratio
- **Delisting Flow** - Complete 5-phase process with time-gated transitions
- **Spinoff Flow** - New token distribution via Merkle claims post-spinoff
- **Ticker Change Flow** - Token migration with symbol update and holder claims
- **Emergency Pause** - Mid-execution pause -> freeze -> supermajority resume
- **Conflicting Actions** - Same token split + delisting conflict handling

### Invariant Tests (5 files)
Continuous property verification:
- Dividend pool total == claimed + unclaimed
- UI multiplier * raw balance == UI balance
- ActionIntent state machine never transitions backward
- Emergency pause freezes all non-query operations
- Fees never exceed configured cap

### Scenario Tests (5 files)
Real-world corporate action replays:
- **Apple (AAPL)** quarterly $0.25/share dividend
- **Nvidia (NVDA)** 10:1 forward split (June 2024)
- **Twitter (TWTR)** delisting at $54.20/share
- **Facebook -> Meta (FB -> META)** ticker change
- **AT&T / Warner Bros. Discovery** spin-off (0.241917 ratio)

### Fuzz Tests
- MultiplierMath round-trip properties (1000+ runs)

## Off-Chain Services

### Data Ingestion
| Source | Adapter | Reliability | Features |
|--------|---------|------------|----------|
| SEC EDGAR | `EdgarMonitor` | 95% | 8-K, 14A, S-4, SC TO-T, 25-NSE polling + RSS fallback on 3 consecutive failures |
| DTCC ISO 20022 | `DtccFeedParser` | 98% | seev.031 notifications, seev.039 cancellations, seev.044 reversals; Redis-backed dedup |
| EOD Historical | `EodHistoricalAdapter` | 85% | Dividend history, stock split calendars |
| Polygon.io | `PolygonAdapter` | 85% | Real-time corporate action events via REST + WebSocket subscription |
| Alpha Vantage | `AlphaVantageAdapter` | 75% | Fallback cross-validation source |
| Bloomberg/Refinitiv | `BloombergAdapter` | 99% | Enterprise-grade DTCC feeds (stub) |

### Event Processing Pipeline
```
Raw Events -> EventDeduplicator (ISIN fallback, effectiveDate composite key, multi-source confidence)
           -> EventClassifier (8-K item-level parsing, SC TO-T, LIQUIDATION, explicit TICKER_CHANGE)
           -> ActionIntentBuilder (ABI encoding for all 10 action types, USDC 6-decimal normalization, ERC-8056 multiplier pre-calc)
           -> MerkleTreeBuilder (distribution trees for DIVIDEND/SPINOFF)
           -> OnChainSubmitter (with ErrorRecovery integration and gas retry)
```

### Validator Node
- On-chain `ActionProposed` event listening via ethers
- Multi-validator coordination via Redis pub/sub
- Independent source verification via `SourceVerifier` (generic `verify()` dispatching by action type)
- ECDSA/EIP-712 signing via `SigningService` integration
- Conflict resolution with Redis-based workflow

### Error Recovery
| Failure | Detection | Recovery |
|---------|-----------|----------|
| EDGAR API down | 3 consecutive failures | RSS feed fallback |
| Tx reverted | ActionFailed event | Re-queue with 2x gas limit |
| Validator offline | Heartbeat timeout (5 min) | Adjust quorum notification |
| Data conflict | Deduplicator conflict flag | Hold in PENDING |
| DB connection failure | Health check | Exponential backoff retry |

## SDK

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

// Subscribe to all corporate action events
client.onAction('0xTokenAddress', (action) => {
  const params = client.decodeActionParams(action.type, action.rawParams);
  console.log(`New ${action.type} for ${action.ticker}`, params);
});

// Granular event subscriptions
client.onDividendClaimed((intentId, claimer, amount) => { /* ... */ });
client.onSplitExecuted((intentId, token, oldMul, newMul) => { /* ... */ });
client.onMergerExecuted((intentId, source, acquiring, type) => { /* ... */ });
client.onDelistingInitiated((intentId, token, finalPrice) => { /* ... */ });

// Query and claim
const pending = await client.getPendingActions({ token: '0x...' });
const tx = await client.claimDividend(intentId, amount, merkleProof, signer);
const adjustment = await client.getStrikePriceAdjustment(intentId);

// Batch claims
await client.claimOnBehalf(intentId, holderAddress, amount, proof, signer);
```

### SDK Features
- 12 granular event subscription methods (ActionValidated, ActionQueued, ActionCancelled, ActionFailed, DividendClaimed, SplitExecuted, MergerExecuted, DelistingInitiated, SpinoffDistributed, TickerMigrated, EmergencyPaused, EmergencyResumed)
- `decodeActionParams()` for typed parameter decoding per action type (all 10 types including LIQUIDATION)
- `claimOnBehalf()` for batch proxy claims
- `getStrikePriceAdjustment()` for derivatives
- Custom error types (`CorpActionError`, `RPCError`, `ContractError`)
- Automatic RPC retry with exponential backoff

## Database

PostgreSQL 16 with 11 tables:

| Table | Purpose |
|-------|---------|
| `raw_events` | Source events with deduplication |
| `corporate_actions` | Normalized, deduplicated actions |
| `event_sources` | Raw event to action linking |
| `merkle_trees` | Distribution tree storage |
| `merkle_leaves` | Individual holder entitlements |
| `execution_log` | On-chain execution audit trail |
| `validator_attestations` | Multi-sig confirmation records |
| `fee_tracking` | Per-action fee collection history |
| `token_registry` | Ticker to token address mapping |
| `holder_snapshots` | Block-specific holder balance cache |

## Monitoring & Alerting

### Prometheus Alert Rules (10 thresholds)
- EDGAR poll latency > 5s
- Zero events ingested for 30min during market hours
- Classification error rate > 1%
- Validator signature collection > 10min
- Any on-chain TX failure
- Merkle tree construction > 60s
- Gas price > 10 gwei sustained
- Unclaimed dividend ratio > 50% at T-7 days
- Contract USDC balance below minimum
- Validator quorum below minimum

### Grafana Dashboard
Full operational dashboard with 11 panels: event ingestion rates, events by source, classification confidence, execution latency, validator health, TX failure rates, gas price tracking, EDGAR poll latency, Unclaimed Dividend Ratio, Contract Balance, and Merkle Tree Construction Time. Auto-provisioned Prometheus datasource.

### Structured Logging
All services use structured JSON logging with timestamp, level, service, component, event, and trace_id fields.

## Fee Schedule

| Action Type | Base Fee | Per-Holder Fee | Cap |
|-------------|---------|---------------|-----|
| Dividend | 100 USDC | 0.01/holder | 10,000 USDC |
| Forward Split | 50 USDC | N/A | 50 USDC |
| Reverse Split | 100 USDC | 0.005/holder | 5,000 USDC |
| Merger (Cash) | 500 USDC | 0.02/holder | 50,000 USDC |
| Merger (Stock/Hybrid) | 1,000 USDC | 0.05/holder | 100,000 USDC |
| Spin-off | 500 USDC | 0.02/holder | 50,000 USDC |
| Delisting | 200 USDC | 0.01/holder | 20,000 USDC |
| Ticker Change | 100 USDC | 0.01/holder | 5,000 USDC |

## Quick Start

```bash
# Clone
git clone https://github.com/wangyangmingsss/corpaction-engine.git
cd corpaction-engine

# Install contract dependencies
cd packages/contracts && forge install

# Build contracts
forge build

# Run all tests (unit, fuzz, integration, invariant, scenario)
forge test -vvv

# Install off-chain service dependencies
cd ../services/ingestion && npm install
cd ../processor && npm install
cd ../validator && npm install

# Install SDK
cd ../../sdk && npm install

# Deploy to testnet
cd ../contracts
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast

# Start full stack with Docker
cd ../..
docker-compose up -d
```

## Repository Structure

```
corpaction-engine/
├── packages/
│   ├── contracts/              # Solidity smart contracts (Foundry)
│   │   ├── src/
│   │   │   ├── core/           # ActionRegistry, ValidatorManager, TimelockController
│   │   │   ├── executors/      # DividendDistributor, SplitExecutor, MergerHandler, etc.
│   │   │   ├── verification/   # AttestationRegistry
│   │   │   ├── fees/           # FeeCollector
│   │   │   ├── interfaces/     # IActionRegistry, IActionExecutor, IERC8056, IAttestationRegistry, IFeeCollector
│   │   │   └── libraries/      # MultiplierMath, ActionLib, MerkleDistributor
│   │   ├── test/
│   │   │   ├── unit/           # 12 unit test files
│   │   │   ├── integration/    # 10 integration test scenarios
│   │   │   ├── fuzz/           # MultiplierMath fuzz tests
│   │   │   ├── invariant/      # 5 invariant property tests
│   │   │   ├── scenarios/      # 5 real-world replay tests
│   │   │   └── mocks/          # MockERC20, MockERC8056, MockValidatorManager, MockAttestationRegistry, MockFeeCollector
│   │   └── script/             # Deploy, ConfigureValidators, RegisterExecutors
│   ├── services/
│   │   ├── ingestion/          # SEC EDGAR + DTCC + financial data monitoring
│   │   │   ├── src/sources/    # EdgarMonitor, DtccFeedParser, EodHistorical, Polygon, AlphaVantage, Bloomberg
│   │   │   ├── src/dedup/      # EventDeduplicator (ISIN fallback, multi-source)
│   │   │   ├── src/classifier/ # EventClassifier (item-level, SC TO-T, LIQUIDATION)
│   │   │   └── test/           # Service tests
│   │   ├── processor/          # Event classification + ActionIntent building
│   │   │   ├── src/builder/    # ActionIntentBuilder, MerkleTreeBuilder, MultiplierCalculator
│   │   │   ├── src/recovery/   # ErrorRecovery (5 strategies)
│   │   │   └── test/           # Service tests
│   │   ├── validator/          # Validator node software
│   │   │   ├── src/            # ValidatorNode, SigningService, SourceVerifier
│   │   │   └── test/           # Service tests
│   │   └── db/                 # PostgreSQL schema (11 tables)
│   ├── shared/                    # @corpaction/shared - Common types, constants, and utilities
│   └── sdk/                    # TypeScript SDK (10 event subscriptions, typed params, retry)
├── monitoring/
│   ├── prometheus.yml          # Scrape config with rules reference
│   ├── prometheus.rules.yml    # 10 alert rules (mounted in docker-compose)
│   └── dashboards/             # Grafana dashboard (11 panels) + datasource provisioning
├── docs/                       # Architecture, API reference, security model, integration guide
├── .github/workflows/          # contracts-ci (+ Slither), services-ci, integration-tests, deploy-testnet, security-audit
├── docker-compose.yml          # Production stack (Postgres, Redis, 3 services, Prometheus, Grafana, postgres-exporter, redis-exporter)
└── Makefile                    # Build automation
```

## Security

- **Multi-signature validation (M-of-N)** for all corporate actions
  - Low severity (ticker change): 2-of-3
  - Medium severity (dividend, split): 3-of-5
  - High severity (merger, delisting): 4-of-5 + mandatory time-lock
- **Time-lock enforcement:** 1h-48h depending on action severity
- **Queue expiration:** QUEUED actions expire after configurable TTL (default 7 days)
- **Emergency circuit breaker:** Any single validator can pause all operations; resume requires supermajority (4-of-5)
- **Action reversal:** EXECUTED actions can be reversed with 5-of-5 (all validators) consensus
- **Source attestation:** Cryptographic proof with EIP-712 typed data signing, linking on-chain actions to SEC filings
- **Fee integration:** Fees collected and validated before action execution
- **Dispute mechanism:** Validators can dispute delistings, triggering pause and potential rollback
- **UUPS proxy upgrades:** 72h time-lock with 4-of-5 validator approval
- **Comprehensive testing:** 100+ tests including unit, fuzz (1000 runs), integration, invariant, and real-world scenario replays

### Enhanced TimelockController

The `TimelockController` enforces mandatory delays per action type before on-chain execution. Delays are configurable by the contract owner and scale with action severity:

- **Low severity** (ticker change): 1 hour minimum delay
- **Medium severity** (dividend, split): 6-12 hour delay
- **High severity** (merger, delisting, liquidation): 24-48 hour delay

The controller integrates with `ActionRegistry` to gate the `execute()` call, ensuring that queued actions cannot bypass the mandatory waiting period. Actions that exceed the queue TTL are automatically expired and must be re-proposed.

## Testnet Deployment

All contracts are deployed to the **Robinhood Chain Testnet** via UUPS proxies:

| Parameter | Value |
|-----------|-------|
| Chain ID | `46630` |
| RPC URL | `https://rpc.testnet.chain.robinhood.com` |
| Block Explorer | `https://explorer.testnet.chain.robinhood.com` |
| USDG Contract | `0x7E955252E15c84f5768B83c41a71F9eba181802F` |

### Deployed Contract Addresses

| Contract | Address |
|----------|---------|
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

### On-Chain Configuration (Live)

The following configuration is live on the deployed contracts:

**Validator Quorum Requirements:**

| Severity | Action Types | Quorum | Timelock |
|----------|-------------|--------|----------|
| Low | Ticker Change | 1-of-1 (demo) | 1 hour |
| Medium | Dividend, Forward Split, Reverse Split | 1-of-1 (demo) | 1-2 hours |
| High | Merger (Cash/Stock/Hybrid), Spinoff, Delisting, Liquidation | 1-of-1 (demo) | 24-48 hours |

> Note: Quorums set to 1-of-1 for testnet demo. Production configuration: Low=2-of-3, Medium=3-of-5, High=4-of-5.

**Fee Schedule (On-Chain, 1000 holders example):**

| Action Type | Calculated Fee |
|-------------|---------------|
| Dividend | 110.0 USDC |
| Forward Split | 50.0 USDC |
| Reverse Split | 105.0 USDC |
| Merger (Cash) | 520.0 USDC |
| Merger (Stock/Hybrid) | 1,050.0 USDC |
| Spinoff | 520.0 USDC |
| Delisting/Liquidation | 210.0 USDC |
| Ticker Change | 110.0 USDC |

### On-Chain Demo Transactions

The following corporate action intents have been proposed on Robinhood Chain Testnet, demonstrating the full ActionRegistry lifecycle:

| Corporate Action | Ticker | Type | Tx Hash | Block |
|-----------------|--------|------|---------|-------|
| AAPL Q2 2026 Dividend ($0.26/share) | AAPL | DIVIDEND | [`0xb8bdbd5f...`](https://explorer.testnet.chain.robinhood.com/tx/0xb8bdbd5f2c4776c0a176baf41dece27059c12de88a80e4729d004294101e1965) | 54496970 |
| NVDA 10:1 Forward Split | NVDA | FORWARD_SPLIT | [`0x9c19406e...`](https://explorer.testnet.chain.robinhood.com/tx/0x9c19406ebe614c9b99b8d3e95fc58529e5a87ef0806ebf922154ded683749ff0) | 54497028 |
| GOOGL 1:20 Reverse Split | GOOGL | REVERSE_SPLIT | [`0xcf406b29...`](https://explorer.testnet.chain.robinhood.com/tx/0xcf406b298389a3af2f86b3dbcd05b02c0f7f66a83e791ace1fd65ea086a3813e) | 54497084 |
| MSFT Cash Merger @ $420/share | MSFT | MERGER_CASH | [`0x4992778c...`](https://explorer.testnet.chain.robinhood.com/tx/0x4992778ca6b7672b28001306560b26b88518539bca758b68d6d2af6f5e0ce5d0) | 54497142 |
| TWTR Delisting @ $54.20 | TWTR | DELISTING | [`0xfdb3e662...`](https://explorer.testnet.chain.robinhood.com/tx/0xfdb3e6629b28ec13c80e283e5d3af5c4f8912e45e31c759b3dbbbbedae9ae43b) | 54497197 |
| FB -> META Ticker Change | FB | TICKER_CHANGE | [`0xff7c0359...`](https://explorer.testnet.chain.robinhood.com/tx/0xff7c0359cd55100b29a3507cb9709eefe71ad58a82529c5789f5c6ee8468d1a4) | 54497252 |
| ATT Spinoff (WBD 0.241917 ratio) | T | SPINOFF | [`0x8c3b2218...`](https://explorer.testnet.chain.robinhood.com/tx/0x8c3b2218cde52812ec615e2c794824fee054da811c26084d0c0833a72e5c0c44) | 54497317 |

**Additional On-Chain Operations:**

| Operation | Tx Hash | Block |
|-----------|---------|-------|
| Submit Attestation (AAPL DIV, SEC_EDGAR) | [`0x9f89349e...`](https://explorer.testnet.chain.robinhood.com/tx/0x9f89349ed9aae35ed71fd519ef470f994bee33384421c76067cc36250bf7bcae) | 54495983 |
| Verify Attestation (AAPL DIV) | [`0xedb25092...`](https://explorer.testnet.chain.robinhood.com/tx/0xedb2509228de223a49f57ff9c603131038fea320f91bd1377600a9f2c0ea5e1d) | 54496041 |
| Emergency Pause (Circuit Breaker) | [`0x4003de99...`](https://explorer.testnet.chain.robinhood.com/tx/0x4003de9944bf596d7d9b7084bce041c6a0e0015e272218d899a7d09bca6fe7e2) | 54494516 |
| Emergency Resume (Super-Majority) | [`0x01cebb20...`](https://explorer.testnet.chain.robinhood.com/tx/0x01cebb2033deb2f86db51b3d7cd9e6816c045235a53f13fbabd07f453541b32c) | 54495735 |
| Cancel Action (ATT Spinoff) | [`0x723e0e42...`](https://explorer.testnet.chain.robinhood.com/tx/0x723e0e420c3baff641a6b5d838998beddab6058b955f1e6d2715a9a09c6e3cc5) | 54497371 |
| Configure Quorum (DIVIDEND) | [`0xd5a40429...`](https://explorer.testnet.chain.robinhood.com/tx/0xd5a40429e4d832350c1835fffa2311b5b905131356629934a9b9d8f0a7c44ba5) | — |
| Configure Quorum (FORWARD_SPLIT) | [`0x389cb3ed...`](https://explorer.testnet.chain.robinhood.com/tx/0x389cb3eda092b13419111dcb243a87b7c0a27e23b944620626421183a1989722) | — |
| Configure Quorum (MERGER_CASH) | [`0xeac6cc1a...`](https://explorer.testnet.chain.robinhood.com/tx/0xeac6cc1a723a7d976f215b549720c8adfb94e70aa63316293ce605ef40cd2346) | — |
| Configure Quorum (DELISTING) | [`0x206ceb6e...`](https://explorer.testnet.chain.robinhood.com/tx/0x206ceb6ebbb71a771e586b1d1f84100483672ecb40aa3bdb426f62599e06d39b) | — |
| Set Super-Majority (1-of-1 demo) | [`0xea0d7f1c...`](https://explorer.testnet.chain.robinhood.com/tx/0xea0d7f1cceb14a9c0495a1d88a6cabfdde2703ad4ada9a9e707b6b19251c2195) | — |

**Total on-chain corporate actions: 7** (6 active + 1 cancelled)

### On-Chain Intent IDs

| Action | Intent ID |
|--------|-----------|
| AAPL Dividend | `0x457c3cdfee64eb87244d7442b03329987bd95b89d622b49bc6c4f7308802e1b0` |
| NVDA 10:1 Split | `0x1e1281e894faf136090f12275a39dcf0d303f29d721c7d1433b392413b255e6e` |
| GOOGL 1:20 Reverse Split | `0xb2580eb02c694b5f71eebd2dc258be7aa7c39417673b9e6681e6c9906b78ea26` |
| MSFT Cash Merger | `0x5d0907fa16cbdb92ec5eb0240c825b7534d1a49870d31961197ca5b32b4fe5fa` |
| TWTR Delisting | `0xe76a3db75f1e7ae4029aa267c989865553c74938ff69040937c8e7e8744dae96` |
| FB->META Ticker Change | `0x5a6ce2840fe31f7fff32f032e97d730766ad5d2d955b42cdc765f7e21aa466b7` |
| ATT Spinoff (cancelled) | `0x1accafb6edcfa13469c3fad0b0060db732eb3018c79bc8cc44e40ed6103672fc` |

### Source Attestation (On-Chain)

| Field | Value |
|-------|-------|
| Intent ID | `0x75a2174f67e458acd8588b6665d86b66e40deeea6fb857a2d87d58baf63cd8f3` |
| Attestation ID | `0x9bb74438cc3f96b3e81c8bd09dcc1dc4a615cbee78ea50260fb1fb09abae796a` |
| Source | SEC_EDGAR |
| Filing | `0000320193-26-000050` |
| Status | Verified |
| EIP-712 | Typed data signature verified on-chain |

## Metrics Endpoints

All off-chain services expose Prometheus-compatible `/metrics` endpoints for operational monitoring:

- **Ingestion service:** Event counts by source, poll latency, RSS fallback triggers
- **Processor service:** Classification throughput, Merkle tree build times, intent submission rates
- **Validator service:** Attestation latency, signature collection times, quorum health

Metrics are scraped by the Prometheus instance defined in `monitoring/prometheus.yml` and visualized in the Grafana dashboard.

## Test Coverage

All off-chain service test suites contain real, meaningful tests (not just placeholder stubs):

- **Ingestion** (7 test files): EDGAR monitor, DTCC parser, EOD Historical, Polygon, Alpha Vantage, Bloomberg adapters, and EventDeduplicator
- **Processor**: ActionIntentBuilder, MerkleTreeBuilder, ErrorRecovery
- **Validator**: ValidatorNode, SigningService, SourceVerifier

Combined with the on-chain test suite (100+ Foundry tests across unit, integration, invariant, scenario, and fuzz categories), the project maintains comprehensive coverage across all layers.

## Development Roadmap

| Phase | Timeline | Deliverables |
|-------|----------|-------------|
| Buildathon | May 25 - Jun 14, 2026 | Core contracts, executor suite, off-chain services, SDK, 100+ tests |
| Founder House | Jun 15 - Jul 9, 2026 | Real EDGAR API, performance optimization, security hardening |
| Mainnet Alpha | Q3 2026 | Deploy to Robinhood Chain mainnet, first pilot partner |
| Enterprise Launch | Q1 2027 | Enterprise API, Bloomberg/Refinitiv integration, multi-chain |

## Competitive Advantages

- **Zero competition:** No project in Arbitrum/EVM offers a dedicated corporate action oracle
- **Standards-first:** Built on ISO 20022 semantics and ERC-8056 compatibility
- **First-mover:** Positioned for Robinhood Chain mainnet launch
- **Network effects:** Once adopted by 2-3 RWA issuers, becomes de facto standard
- **Production-grade:** Comprehensive testing, monitoring, alerting, and error recovery

## Built For

- **Arbitrum Open House London Online Buildathon** (May 25 - June 14, 2026)
- **Robinhood Chain** ecosystem
- **Arbitrum** platform

## License

MIT
