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
| `ActionRegistry` | Central lifecycle registry (propose -> validate -> queue -> execute) | Fee/attestation integration, reverseAction(), queue expiration, intent TTL |
| `ValidatorManager` | Validator set, signature verification, severity-based quorum | Dynamic validator management, EIP-191 signatures |
| `TimelockController` | Mandatory delays per action type (1h-48h) | Configurable per action type |
| `DividendDistributor` | Merkle-tree USDC pull distribution | Withholding tax (basis points), snapshotBlock tracking, claim deadlines |
| `SplitExecutor` | ERC-8056 `setUIMultiplier` for splits | Cash-in-lieu for reverse split fractionals via Merkle claims |
| `MergerHandler` | Cash-only, stock-for-stock, hybrid mergers | Election mechanism, proration factor, cash pool validation, finalize |
| `SpinoffExecutor` | New token distribution via Merkle claims | Claim deadlines, proof verification |
| `DelistingManager` | 5-phase delisting process | Each phase transitions individually, dispute/rollback, claim deadline |
| `TickerMigrator` | Symbol/address migration with balance snapshot | Merkle-based claim for new tokens |
| `AttestationRegistry` | Cryptographic source attestation | Submit, verify, query attestations per intent |
| `FeeCollector` | Per-action fee calculation and collection | Configurable schedule with caps |

## Testing

Comprehensive testing suite with 100+ tests across 5 categories:

### Unit Tests (9 files)
Every contract has dedicated unit tests covering happy paths, revert conditions, edge cases, access control, and state transitions:
- `ActionRegistry.t.sol` - Proposal, validation, execution, cancellation, emergency, timelock, TTL, routing, permissions
- `ValidatorManager.t.sol` - Add/remove validators, quorum, signatures, super majority
- `DividendDistributor.t.sol` - Execute, claim, withholding tax, double-claim, expiry, reclaim
- `SplitExecutor.t.sol` - Forward/reverse splits, cash-in-lieu, multiplier verification
- `MergerHandler.t.sol` - All 3 merger types, elections, proration, finalization
- `DelistingManager.t.sol` - All 5 phases, claims, disputes, rollback
- `SpinoffExecutor.t.sol` - Execute, claim, proof verification, deadlines
- `TickerMigrator.t.sol` - Execute, claim migration, proof verification
- `FeeCollector.t.sol` - Fee calculation per type, caps, collection, permissions
- `AttestationRegistry.t.sol` - Submit, verify, query, access control

### Integration Tests (7 files)
End-to-end scenarios exercising the full pipeline:
- **Dividend Flow** - Full propose -> validate -> execute -> Merkle claim pipeline
- **Stock Split** - 4:1 forward split -> multiplier verification -> balanceOfUI
- **Reverse Split + Fractional** - 1:10 reverse split -> cash-in-lieu claims
- **Merger Flow** - Stock-for-stock -> freeze -> distribute -> exchange ratio
- **Delisting Flow** - Complete 5-phase process
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
| DTCC ISO 20022 | `DtccFeedParser` | 98% | seev.031 corporate action notification parsing |
| EOD Historical | `EodHistoricalAdapter` | 85% | Dividend history, stock split calendars |
| Polygon.io | `PolygonAdapter` | 85% | Real-time corporate action events |
| Alpha Vantage | `AlphaVantageAdapter` | 75% | Fallback cross-validation source |
| Bloomberg/Refinitiv | `BloombergAdapter` | 99% | Enterprise-grade DTCC feeds (stub) |

### Event Processing Pipeline
```
Raw Events -> EventDeduplicator (ISIN fallback, parameter comparison, confidence promotion)
           -> EventClassifier (8-K item-level parsing, SC TO-T, LIQUIDATION)
           -> ActionIntentBuilder (ERC-8056 multiplier pre-calc, overflow protection)
           -> OnChainSubmitter (with error recovery and gas retry)
```

### Validator Node
- On-chain `ActionProposed` event listening via ethers
- Multi-validator coordination via Redis pub/sub
- Independent source verification via `SourceVerifier`
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
  rpcUrl: 'https://rpc.chain.robinhood.com',
  registryAddress: '0x...',
  dividendDistributorAddress: '0x...',
  splitExecutorAddress: '0x...',
  mergerHandlerAddress: '0x...',
  delistingManagerAddress: '0x...',
  spinoffExecutorAddress: '0x...',
  tickerMigratorAddress: '0x...',
  chainId: 42161,
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
- 10 granular event subscription methods (ActionValidated, ActionQueued, ActionCancelled, ActionFailed, DividendClaimed, SplitExecuted, MergerExecuted, DelistingInitiated, SpinoffDistributed, TickerMigrated)
- `decodeActionParams()` for typed parameter decoding per action type
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
Full operational dashboard with event ingestion rates, classification confidence, execution latency, validator health, TX failure rates, gas price tracking.

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
│   │   │   ├── unit/           # 10 unit test files
│   │   │   ├── integration/    # 7 integration test scenarios
│   │   │   ├── fuzz/           # MultiplierMath fuzz tests
│   │   │   ├── invariant/      # 5 invariant property tests
│   │   │   ├── scenarios/      # 5 real-world replay tests
│   │   │   └── mocks/          # MockERC20, MockERC8056, MockValidatorManager
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
│   └── sdk/                    # TypeScript SDK (10 event subscriptions, typed params, retry)
├── monitoring/
│   ├── prometheus.yml          # Scrape config with rules reference
│   ├── prometheus.rules.yml    # 10 alert rules
│   └── dashboards/             # Grafana dashboard with proper datasource config
├── docs/                       # Architecture, API reference, security model, integration guide
├── .github/workflows/          # contracts-ci, services-ci, integration-tests, deploy-testnet, security-audit
├── docker-compose.yml          # Production stack (Postgres, Redis, 3 services, Prometheus, Grafana)
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
- **Source attestation:** Cryptographic proof linking on-chain actions to SEC filings, verified before execution
- **Fee integration:** Fees collected and validated before action execution
- **Dispute mechanism:** Validators can dispute delistings, triggering pause and potential rollback
- **UUPS proxy upgrades:** 72h time-lock with 4-of-5 validator approval
- **Comprehensive testing:** 100+ tests including unit, fuzz (1000 runs), integration, invariant, and real-world scenario replays

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
