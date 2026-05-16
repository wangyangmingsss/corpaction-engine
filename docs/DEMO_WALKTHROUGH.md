# Demo Walkthrough

This document provides step-by-step instructions for running the CorpAction Engine demo locally and on the Robinhood Chain Testnet.

---

## Quick Demo (Local Anvil)

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed (`forge`, `anvil`, `cast`)
- Node.js 18+
- Git

### Setup

```bash
# Clone the repository
git clone https://github.com/wangyangmingsss/corpaction-engine.git
cd corpaction-engine

# Install contract dependencies
cd packages/contracts
forge install

# Build all contracts
forge build
```

### Run the Full Test Suite

```bash
# Run all tests (unit, integration, invariant, scenario, fuzz)
forge test -vvv
```

### Local Anvil Deployment

Start a local Anvil fork and deploy the full contract suite:

```bash
# Terminal 1: Start Anvil
anvil --chain-id 31337 --block-time 1

# Terminal 2: Deploy contracts
cd packages/contracts
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Configure validators
forge script script/ConfigureValidators.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Register executor contracts
forge script script/RegisterExecutors.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

---

## Expected Output: Full 7-Step Process

The following shows the complete lifecycle for an AAPL quarterly dividend action, demonstrating all seven stages of the CorpAction Engine pipeline.

### Step 1: Ingestion

The ingestion service detects a new 8-K filing from SEC EDGAR announcing AAPL's quarterly dividend.

```
[2026-05-16T14:00:01Z] INFO  ingestion.edgar  | event=filing_detected
  filing_type=8-K accession=0000320193-26-000050 issuer=AAPL
  item=Item 8.01 description="Declaration of quarterly dividend"

[2026-05-16T14:00:01Z] INFO  ingestion.dedup  | event=new_event
  isin=US0378331005 source=SEC_EDGAR confidence=0.95
  effective_date=2026-06-15 dedup_key=AAPL-DIVIDEND-2026Q2
```

### Step 2: Classification and Normalization

The event classifier identifies the action type and the ActionIntent builder constructs the on-chain payload.

```
[2026-05-16T14:00:02Z] INFO  processor.classifier | event=classified
  type=DIVIDEND ticker=AAPL confidence=0.98
  amount_per_share=0.260000 payment_token=USDG

[2026-05-16T14:00:02Z] INFO  processor.builder    | event=intent_built
  intent_id=0x457c3cdf...e1b0 action_type=DIVIDEND
  target_token=0xAAPL total_amount=2340000.000000
  merkle_root=0x8a3f...b2c1 snapshot_block=54496900
```

### Step 3: Proposal (On-Chain)

The intent is submitted to the ActionRegistry with a validator signature.

```
[2026-05-16T14:00:05Z] INFO  submitter | event=action_proposed
  tx=0xb8bdbd5f...1965 block=54496970 gas_used=178432
  intent_id=0x457c3cdf...e1b0 type=DIVIDEND ticker=AAPL
  state=PROPOSED
```

### Step 4: Validation (Quorum Reached)

Validators independently verify the source data and sign the intent.

```
[2026-05-16T14:00:15Z] INFO  validator.node | event=source_verified
  intent_id=0x457c3cdf...e1b0 source=SEC_EDGAR
  filing=0000320193-26-000050 verified=true

[2026-05-16T14:00:16Z] INFO  validator.node | event=validation_submitted
  tx=0xa1b2c3d4...ef56 validator=0xVal1 count=1 required=1
  state=VALIDATED (quorum reached)
```

### Step 5: Queue (Timelock Started)

The action enters the timelock queue. For dividends, the minimum delay is 1 hour.

```
[2026-05-16T14:00:20Z] INFO  registry | event=action_queued
  intent_id=0x457c3cdf...e1b0 state=QUEUED
  execution_time=2026-05-16T15:00:20Z timelock=3600s
```

### Step 6: Execution

After the timelock expires, the action is executed on-chain.

```
[2026-05-16T15:00:25Z] INFO  executor | event=action_executed
  tx=0xd4e5f6a7...8901 block=54501200 gas_used=148923
  intent_id=0x457c3cdf...e1b0 type=DIVIDEND
  total_amount=2340000.000000 merkle_root=0x8a3f...b2c1
  fee_collected=110.000000 USDC state=EXECUTED
```

### Step 7: Claims

Token holders claim their dividends using Merkle proofs.

```
[2026-05-16T15:05:00Z] INFO  claim | event=dividend_claimed
  intent_id=0x457c3cdf...e1b0 claimer=0xHolder1
  gross_amount=260.000000 withholding_bps=0 net_amount=260.000000
  tx=0x1234abcd...5678

[2026-05-16T15:05:30Z] INFO  claim | event=dividend_claimed
  intent_id=0x457c3cdf...e1b0 claimer=0xHolder2
  gross_amount=130.000000 withholding_bps=1500 withheld=19.500000
  net_amount=110.500000 tx=0x9876fedc...ba01
```

---

## Testnet Demo: On-Chain Transactions

The following corporate actions have been proposed and recorded on the Robinhood Chain Testnet, demonstrating the full ActionRegistry lifecycle.

### Corporate Action Proposals

| Corporate Action | Ticker | Type | Tx Hash | Block |
|---|---|---|---|---|
| AAPL Q2 2026 Dividend ($0.26/share) | AAPL | DIVIDEND | [`0xb8bdbd5f...`](https://explorer.testnet.chain.robinhood.com/tx/0xb8bdbd5f2c4776c0a176baf41dece27059c12de88a80e4729d004294101e1965) | 54496970 |
| NVDA 10:1 Forward Split | NVDA | FORWARD_SPLIT | [`0x9c19406e...`](https://explorer.testnet.chain.robinhood.com/tx/0x9c19406ebe614c9b99b8d3e95fc58529e5a87ef0806ebf922154ded683749ff0) | 54497028 |
| GOOGL 1:20 Reverse Split | GOOGL | REVERSE_SPLIT | [`0xcf406b29...`](https://explorer.testnet.chain.robinhood.com/tx/0xcf406b298389a3af2f86b3dbcd05b02c0f7f66a83e791ace1fd65ea086a3813e) | 54497084 |
| MSFT Cash Merger @ $420/share | MSFT | MERGER_CASH | [`0x4992778c...`](https://explorer.testnet.chain.robinhood.com/tx/0x4992778ca6b7672b28001306560b26b88518539bca758b68d6d2af6f5e0ce5d0) | 54497142 |
| TWTR Delisting @ $54.20 | TWTR | DELISTING | [`0xfdb3e662...`](https://explorer.testnet.chain.robinhood.com/tx/0xfdb3e6629b28ec13c80e283e5d3af5c4f8912e45e31c759b3dbbbbedae9ae43b) | 54497197 |
| FB to META Ticker Change | FB | TICKER_CHANGE | [`0xff7c0359...`](https://explorer.testnet.chain.robinhood.com/tx/0xff7c0359cd55100b29a3507cb9709eefe71ad58a82529c5789f5c6ee8468d1a4) | 54497252 |
| ATT Spinoff (WBD 0.241917 ratio) | T | SPINOFF | [`0x8c3b2218...`](https://explorer.testnet.chain.robinhood.com/tx/0x8c3b2218cde52812ec615e2c794824fee054da811c26084d0c0833a72e5c0c44) | 54497317 |

### Attestation and Governance Operations

| Operation | Tx Hash | Block |
|---|---|---|
| Submit Attestation (AAPL DIV, SEC_EDGAR) | [`0x9f89349e...`](https://explorer.testnet.chain.robinhood.com/tx/0x9f89349ed9aae35ed71fd519ef470f994bee33384421c76067cc36250bf7bcae) | 54495983 |
| Verify Attestation (AAPL DIV) | [`0xedb25092...`](https://explorer.testnet.chain.robinhood.com/tx/0xedb2509228de223a49f57ff9c603131038fea320f91bd1377600a9f2c0ea5e1d) | 54496041 |
| Emergency Pause (Circuit Breaker) | [`0x4003de99...`](https://explorer.testnet.chain.robinhood.com/tx/0x4003de9944bf596d7d9b7084bce041c6a0e0015e272218d899a7d09bca6fe7e2) | 54494516 |
| Emergency Resume (Super-Majority) | [`0x01cebb20...`](https://explorer.testnet.chain.robinhood.com/tx/0x01cebb2033deb2f86db51b3d7cd9e6816c045235a53f13fbabd07f453541b32c) | 54495735 |
| Cancel Action (ATT Spinoff) | [`0x723e0e42...`](https://explorer.testnet.chain.robinhood.com/tx/0x723e0e420c3baff641a6b5d838998beddab6058b955f1e6d2715a9a09c6e3cc5) | 54497371 |

### Intent IDs

| Action | Intent ID |
|---|---|
| AAPL Dividend | `0x457c3cdfee64eb87244d7442b03329987bd95b89d622b49bc6c4f7308802e1b0` |
| NVDA 10:1 Split | `0x1e1281e894faf136090f12275a39dcf0d303f29d721c7d1433b392413b255e6e` |
| GOOGL 1:20 Reverse Split | `0xb2580eb02c694b5f71eebd2dc258be7aa7c39417673b9e6681e6c9906b78ea26` |
| MSFT Cash Merger | `0x5d0907fa16cbdb92ec5eb0240c825b7534d1a49870d31961197ca5b32b4fe5fa` |
| TWTR Delisting | `0xe76a3db75f1e7ae4029aa267c989865553c74938ff69040937c8e7e8744dae96` |
| FB to META Ticker Change | `0x5a6ce2840fe31f7fff32f032e97d730766ad5d2d955b42cdc765f7e21aa466b7` |
| ATT Spinoff (cancelled) | `0x1accafb6edcfa13469c3fad0b0060db732eb3018c79bc8cc44e40ed6103672fc` |

---

## Running the Full Stack Locally

For a complete end-to-end demo with all off-chain services:

```bash
# Start PostgreSQL, Redis, ingestion, processor, validator, Prometheus, Grafana
docker-compose up -d

# Verify services are running
docker-compose ps

# Check Prometheus metrics
curl http://localhost:9090/metrics

# Open Grafana dashboard
open http://localhost:3000
# Default credentials: admin / admin
```

### Service Endpoints

| Service | URL | Purpose |
|---|---|---|
| Ingestion `/metrics` | `http://localhost:3001/metrics` | Event counts, poll latency, RSS fallback triggers |
| Processor `/metrics` | `http://localhost:3002/metrics` | Classification throughput, Merkle build times |
| Validator `/metrics` | `http://localhost:3003/metrics` | Attestation latency, quorum health |
| Prometheus | `http://localhost:9090` | Metrics aggregation and alerting |
| Grafana | `http://localhost:3000` | Operational dashboard (11 panels) |

---

## Troubleshooting

| Issue | Cause | Resolution |
|---|---|---|
| `NotERC8056Compliant` revert | Target token does not implement `uiMultiplier()` | Deploy an ERC-8056 compliant token or use MockERC8056 for testing |
| `IntentExpired` revert | Proposal exceeded `intentTTL` before reaching quorum | Re-propose the action; check validator availability |
| `QueueExpired` revert | Queued action exceeded `queuedTTL` (default 7 days) | Re-propose and execute within the TTL window |
| `TimelockNotExpired` revert | Attempted execution before timelock elapsed | Wait for the timelock duration to pass |
| `InsufficientFunds` revert | DividendDistributor not funded with payment tokens | Transfer USDG to the DividendDistributor contract before execution |
| Validator not signing | Validator node offline or misconfigured | Check validator heartbeat; verify Redis pub/sub connectivity |
