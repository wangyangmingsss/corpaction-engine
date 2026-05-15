# CorpAction Engine

**Tokenized Equity Corporate Action Automation Engine for Robinhood Chain / Arbitrum**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Solidity](https://img.shields.io/badge/solidity-0.8.24-363636.svg)
![Foundry](https://img.shields.io/badge/built%20with-Foundry-FFDB1C.svg)
![Tests](https://img.shields.io/badge/tests-19%20passing-brightgreen.svg)
![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen.svg)

## The Problem

Robinhood Chain tokenizes 500+ US equities. But real stocks experience corporate actions daily: dividends, splits, mergers, spin-offs, delistings. Every single one needs its on-chain counterpart to execute in sync, or the token diverges from reality.

Today, **every RWA platform handles this manually**. There is no open, composable, standardized infrastructure for tokenized equity lifecycle management.

## The Solution

CorpAction Engine is a **Corporate Action Oracle + Execution Engine** that:

1. **Monitors** SEC EDGAR and financial data APIs for corporate action events
2. **Normalizes** events into on-chain Action Intents (ISO 20022-inspired schema)
3. **Executes** on Robinhood Chain: USDC dividends, ERC-8056 splits, token mergers, delisting freezes
4. **Attests** every action with verifiable source provenance + multi-sig confirmation

## Architecture

```
SEC EDGAR / Data APIs  -->  Ingestion Layer  -->  Normalization Engine
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
| Data Ingestion | SEC EDGAR Monitor, EOD Historical, Polygon.io, Event Deduplicator | TypeScript, Redis |
| Normalization | Event Classifier, ISO 20022 Mapper, ActionIntent Builder | TypeScript, Rule Engine |
| On-Chain Execution | ActionRegistry, 6 Executor Contracts, AttestationRegistry | Solidity 0.8.24, Foundry, OpenZeppelin 5.x |
| Attestation & Governance | Multi-sig Validator, Source Attestation, Audit Trail | Solidity, ECDSA, EIP-712 |

## Supported Corporate Actions

| Action | On-Chain Execution | Standard |
|--------|-------------------|----------|
| Dividend | Merkle-based USDC distribution (pull/claim) | ISO 20022 seev.031 |
| Stock Split (Forward) | ERC-8056 UI multiplier update | ERC-8056 |
| Stock Split (Reverse) | ERC-8056 + fractional cash-in-lieu | ERC-8056 |
| Merger (Cash) | Position liquidation + USDC payout | ISO 20022 seev.036 |
| Merger (Stock) | Token swap at exchange ratio | ISO 20022 seev.036 |
| Merger (Hybrid) | Combined cash + stock consideration | ISO 20022 seev.036 |
| Spin-off | New token deployment + Merkle distribution | ISO 20022 seev.031 |
| Delisting | 5-phase freeze + forced liquidation | ISO 20022 seev.039 |
| Ticker Change | Token migration with symbol update | N/A |

## Smart Contracts

| Contract | Purpose |
|----------|---------|
| `ActionRegistry` | Central registry for corporate action lifecycle (propose → validate → queue → execute) |
| `ValidatorManager` | Manages validator set, signature verification, severity-based quorum logic |
| `TimelockController` | Enforces mandatory delays per action type (1h–48h) |
| `DividendDistributor` | Merkle-tree-based USDC pull distribution with claim deadlines |
| `SplitExecutor` | ERC-8056 `setUIMultiplier` calls for forward/reverse splits |
| `MergerHandler` | Cash-only, stock-for-stock, and hybrid merger execution |
| `SpinoffExecutor` | New token distribution via Merkle claims |
| `DelistingManager` | 5-phase delisting: announce → sell-only → price lock → liquidate → freeze |
| `TickerMigrator` | Symbol/address migration with balance snapshot |
| `AttestationRegistry` | Cryptographic source attestation storage and verification |
| `FeeCollector` | Per-action fee calculation and collection |

## Quick Start

```bash
# Clone
git clone https://github.com/wangyangmingsss/corpaction-engine.git
cd corpaction-engine

# Install contract dependencies
cd packages/contracts && forge install

# Build contracts
forge build

# Run tests (19 tests: unit, fuzz, integration)
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

## Security

- **Multi-signature validation (M-of-N)** for all corporate actions
  - Low severity (ticker change): 2-of-3
  - Medium severity (dividend, split): 3-of-5
  - High severity (merger, delisting): 4-of-5 + mandatory time-lock
- **Time-lock enforcement:** 1h–48h depending on action severity
- **Emergency circuit breaker:** Any single validator can pause all operations
- **Source attestation:** Cryptographic proof linking on-chain actions to SEC filings
- **UUPS proxy upgrades:** 72h time-lock with 4-of-5 validator approval
- **Comprehensive testing:** 19 tests including unit, fuzz (1000 runs), and integration

## SDK Usage

```typescript
import { CorpActionClient } from '@corpaction/sdk';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.chain.robinhood.com',
  registryAddress: '0x...',
  chainId: 42161,
});

// Subscribe to corporate actions for a specific token
client.onAction('0xTokenAddress', (action) => {
  console.log(`New ${action.type} for ${action.ticker}`);
});

// Query pending actions
const pending = await client.getPendingActions({ token: '0x...' });

// Claim dividend with Merkle proof
const tx = await client.claimDividend(intentId, amount, merkleProof, signer);
```

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
│   │   │   ├── interfaces/     # IActionRegistry, IActionExecutor, IERC8056, etc.
│   │   │   └── libraries/      # MultiplierMath, ActionLib, MerkleDistributor
│   │   ├── test/               # Unit, fuzz, integration, invariant tests
│   │   └── script/             # Deployment scripts
│   ├── services/
│   │   ├── ingestion/          # SEC EDGAR + financial data monitoring
│   │   ├── processor/          # Event classification + ActionIntent building
│   │   ├── validator/          # Validator node software
│   │   └── db/                 # PostgreSQL schema
│   └── sdk/                    # TypeScript SDK for integrators
├── monitoring/                 # Prometheus + Grafana dashboards
├── docs/                       # Architecture, API reference, security model
├── .github/workflows/          # CI/CD pipelines
├── docker-compose.yml          # Production stack
└── Makefile                    # Build automation
```

## Development Roadmap

| Phase | Timeline | Deliverables |
|-------|----------|-------------|
| Buildathon | May 25 – Jun 14, 2026 | Core contracts, executor suite, off-chain services, SDK, tests |
| Founder House | Jun 15 – Jul 9, 2026 | Real EDGAR API, performance optimization, security hardening |
| Mainnet Alpha | Q3 2026 | Deploy to Robinhood Chain mainnet, first pilot partner |
| Enterprise Launch | Q1 2027 | Enterprise API, Bloomberg/Refinitiv integration, multi-chain |

## Competitive Advantages

- **Zero competition:** No project in Arbitrum/EVM offers a dedicated corporate action oracle
- **Standards-first:** Built on ISO 20022 semantics and ERC-8056 compatibility
- **First-mover:** Positioned for Robinhood Chain mainnet launch
- **Network effects:** Once adopted by 2–3 RWA issuers, becomes de facto standard

## Built For

- **Arbitrum Open House London Online Buildathon** (May 25 – June 14, 2026)
- **Robinhood Chain** ecosystem
- **Arbitrum** platform

## License

MIT
