# Economics and Business Model

## Market Opportunity

### The Problem

Every RWA (Real-World Asset) platform that tokenizes equities faces the same operational burden: corporate actions. Dividends, stock splits, mergers, delistings, and spin-offs occur continuously across US markets. Today, every platform handles these manually -- a process that is slow, error-prone, and unscalable.

There is no open, composable, standardized infrastructure for tokenized equity lifecycle management. CorpAction Engine fills this gap as a **Corporate Action Oracle and Execution Engine**.

### Total Addressable Market (TAM) Analysis

The TAM grows with the number of RWA platforms tokenizing equities and the volume of corporate actions they must process.

| Year | RWA Platforms Served | Avg. Tokens per Platform | Corporate Actions / Token / Year | Actions Processed / Year | Revenue |
|---|---|---|---|---|---|
| Y1 (2027) | 3 | 100 | 8 | 2,400 | $600K |
| Y2 (2028) | 8 | 200 | 10 | 16,000 | $3.2M |
| Y3 (2029) | 15 | 350 | 12 | 63,000 | $9.5M |
| Y4 (2030) | 22 | 400 | 12 | 105,600 | $16M |
| Y5 (2031) | 30 | 500 | 14 | 210,000 | $24M |

**Key assumptions:**
- Average 8-14 corporate actions per tokenized equity per year (dividends quarterly, occasional splits/mergers)
- Platform count grows as RWA tokenization adoption accelerates (driven by institutional demand and regulatory clarity)
- Revenue per action increases as enterprise tiers are adopted

---

## Cost Savings vs. Manual Processing

### Current Manual Process

Each corporate action requires a team of operations staff to:

1. Monitor SEC filings, DTCC notifications, and financial data feeds
2. Classify and normalize the event
3. Calculate holder entitlements (snapshot balances, Merkle trees, tax withholding)
4. Submit on-chain transactions manually
5. Handle claims, disputes, and reconciliation
6. Audit and report

**Estimated manual cost per corporate action:** $250 - $1,500 (depending on complexity)

### Automated Process with CorpAction Engine

| Cost Category | Manual (Annual, 1000 actions) | Automated (Annual, 1000 actions) | Savings |
|---|---|---|---|
| Operations staff (2-3 FTEs) | $450,000 | $80,000 (1 FTE monitoring) | $370,000 |
| Error correction and reconciliation | $180,000 | $15,000 | $165,000 |
| Compliance and audit | $200,000 | $60,000 | $140,000 |
| On-chain gas costs | $120,000 | $45,000 | $75,000 |
| Missed/delayed action penalties | $350,000 | $0 | $350,000 |
| Software and infrastructure | $50,000 | $100,000 | ($50,000) |
| **Total** | **$1,350,000** | **$300,000** | **$1,050,000** |

**For a platform processing 2,000 actions/year:**

| Metric | Value |
|---|---|
| Manual annual cost | $2,150,000 |
| Automated annual cost | $460,000 |
| Annual savings | $1,690,000 |
| **Cost reduction** | **~65% ($1.4M/yr average)** |
| Payback period | < 3 months |

### Additional Qualitative Benefits

- **Speed**: Actions execute within minutes of detection vs. hours/days manually
- **Accuracy**: Deterministic on-chain execution eliminates human calculation errors
- **Auditability**: Every action is cryptographically attested with source provenance
- **Composability**: Other DeFi protocols can subscribe and react automatically

---

## Revenue Model

CorpAction Engine generates revenue through two primary channels:

### 1. Per-Action Fees

Collected on-chain via the `FeeCollector` contract at the time of execution.

| Action Type | Base Fee | Per-Holder Fee | Cap | Typical Fee (1,000 holders) |
|---|---|---|---|---|
| Dividend | 100 USDC | 0.01 / holder | 10,000 USDC | 110 USDC |
| Forward Split | 50 USDC | N/A | 50 USDC | 50 USDC |
| Reverse Split | 100 USDC | 0.005 / holder | 5,000 USDC | 105 USDC |
| Merger (Cash) | 500 USDC | 0.02 / holder | 50,000 USDC | 520 USDC |
| Merger (Stock/Hybrid) | 1,000 USDC | 0.05 / holder | 100,000 USDC | 1,050 USDC |
| Spin-off | 500 USDC | 0.02 / holder | 50,000 USDC | 520 USDC |
| Delisting | 200 USDC | 0.01 / holder | 20,000 USDC | 210 USDC |
| Ticker Change | 100 USDC | 0.01 / holder | 5,000 USDC | 110 USDC |

**Fee projection by year:**

| Year | Actions Processed | Avg Fee / Action | Per-Action Revenue | % of Total Revenue |
|---|---|---|---|---|
| Y1 | 2,400 | $120 | $288,000 | 48% |
| Y2 | 16,000 | $115 | $1,840,000 | 58% |
| Y3 | 63,000 | $100 | $6,300,000 | 66% |
| Y4 | 105,600 | $95 | $10,032,000 | 63% |
| Y5 | 210,000 | $80 | $16,800,000 | 70% |

> Per-action fees decrease over time due to volume discounts for enterprise customers, but total revenue grows with action volume.

### 2. Enterprise Subscriptions

Monthly/annual subscriptions for dedicated infrastructure, SLAs, and premium data sources.

| Tier | Monthly Price | Included Actions | Additional Features |
|---|---|---|---|
| **Starter** | $2,500/mo | Up to 200/mo | Standard data sources (EDGAR, EOD Historical, Polygon), shared validator set, community support, 99.5% uptime SLA |
| **Growth** | $8,000/mo | Up to 1,000/mo | All Starter features + DTCC ISO 20022 feed, dedicated validator node, priority support, 99.9% uptime SLA, custom fee schedule |
| **Enterprise** | $25,000/mo | Unlimited | All Growth features + Bloomberg/Refinitiv feeds, private validator quorum, dedicated infrastructure, 99.99% uptime SLA, custom integrations, on-call engineering support |
| **Custom** | Contact sales | Negotiated | Multi-chain deployment, white-label, custom executor contracts, regulatory compliance modules |

**Subscription revenue projection:**

| Year | Starter Clients | Growth Clients | Enterprise Clients | Annual Subscription Revenue |
|---|---|---|---|---|
| Y1 | 2 | 1 | 0 | $156,000 |
| Y2 | 4 | 3 | 1 | $684,000 |
| Y3 | 6 | 5 | 2 | $1,116,000 |
| Y4 | 8 | 8 | 3 | $2,364,000 |
| Y5 | 10 | 10 | 5 | $3,660,000 |

---

## Margin Analysis

### Gross Margin: ~85%

| Revenue Component | Gross Margin | Rationale |
|---|---|---|
| Per-action fees | ~92% | Near-zero marginal cost (gas is paid by the protocol, infrastructure is fixed) |
| Enterprise subscriptions | ~75% | Dedicated infrastructure and support staff costs |
| **Blended** | **~85%** | Weighted average across both channels |

### Cost Structure

| Cost Category | Y1 | Y3 | Y5 |
|---|---|---|---|
| Infrastructure (AWS/cloud, RPC nodes) | $48,000 | $180,000 | $480,000 |
| Data source licenses (DTCC, Bloomberg) | $36,000 | $120,000 | $240,000 |
| Engineering team (3 to 8 FTEs) | $450,000 | $960,000 | $1,600,000 |
| Validator operations | $24,000 | $96,000 | $240,000 |
| Gas costs (L2 execution) | $12,000 | $60,000 | $180,000 |
| **Total COGS** | **$570,000** | **$1,416,000** | **$2,740,000** |
| **Revenue** | **$600,000** | **$9,500,000** | **$24,000,000** |
| **Gross Profit** | **$30,000** | **$8,084,000** | **$21,260,000** |
| **Gross Margin** | **5%** | **85%** | **89%** |

> Y1 margins are thin as initial engineering and infrastructure costs are amortized. The model reaches strong profitability by Y2 as per-action volume scales with near-zero marginal cost.

---

## Comparable: Chainlink Oracle Infrastructure

CorpAction Engine occupies a similar market position to Chainlink in the oracle infrastructure space, but specialized for corporate action data rather than price feeds.

| Dimension | Chainlink (Price Feeds) | CorpAction Engine (Corporate Actions) |
|---|---|---|
| **Data type** | Asset prices, VRF, CCIP | Corporate actions (dividends, splits, mergers) |
| **Data sources** | 15+ premium data aggregators | SEC EDGAR, DTCC ISO 20022, EOD Historical, Polygon, Bloomberg |
| **Validation** | Decentralized oracle network (DON) | M-of-N validator quorum with severity-based thresholds |
| **Revenue model** | Per-request fees + LINK staking | Per-action fees + enterprise subscriptions |
| **Standards** | ERC-677 (LINK token) | ERC-8056, ISO 20022 (seev.031, seev.036, seev.039) |
| **Moat** | Network effects, integrations | First-mover in corporate action automation, standards adoption |
| **TAM** | $30B+ (all DeFi price data) | $500M+ (tokenized equity lifecycle, growing with RWA adoption) |
| **Gross margin** | ~85-90% | ~85% at scale |

### Why the Comparison Matters

Chainlink proved that standardized oracle infrastructure becomes a utility layer that every DeFi protocol depends on. CorpAction Engine aims to become the equivalent utility layer for tokenized equities. Just as no lending protocol builds its own price feed, no RWA platform should build its own corporate action pipeline.

---

## Summary

| Metric | Value |
|---|---|
| **Y1 Revenue** | $600K |
| **Y5 Revenue** | $24M |
| **Revenue CAGR** | ~150% |
| **Cost savings vs. manual** | 65% ($1.4M/yr per platform) |
| **Gross margin at scale** | ~85% |
| **Payback period for customers** | < 3 months |
| **Revenue mix (Y5)** | 70% per-action fees, 30% enterprise subscriptions |
| **Comparable** | Chainlink oracle infrastructure |
