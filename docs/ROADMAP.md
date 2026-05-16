# CorpAction Engine - Founder House Positioning Roadmap

> On-chain corporate actions processing, built for RH Chain and the broader EVM ecosystem.

---

## Phase 1: Buildathon (May 25 - Jun 14, 2026)

**Objective:** Deliver a working prototype with core contracts, comprehensive tests, and a live demo.

### Milestones

- ERC-8056 compliant CorporateActionEngine contract deployed to testnet
- Stock split, dividend, and merger action types fully implemented
- Fuzz and unit test suites passing with >80% coverage
- End-to-end demo script demonstrating a stock split lifecycle

### Deliverables

| Deliverable | Target Date |
|---|---|
| Core contract suite (CorporateActionEngine, ActionRegistry, EntitlementCalculator) | Jun 1 |
| Unit + fuzz test suite | Jun 7 |
| Demo walkthrough and deployment scripts | Jun 12 |
| Buildathon submission package | Jun 14 |

### KPIs

- Test coverage: >= 80%
- Gas per action lifecycle (create -> approve -> execute): < 500k gas
- Zero high-severity Slither findings

---

## Phase 2: Founder House Prep (Jun 15 - Jul 9, 2026)

**Objective:** Harden security, optimize performance, and prepare investor-ready materials.

### Milestones

- Independent security review completed (internal + Slither + manual audit)
- Gas optimizations applied to all hot paths
- Integration guide and API reference documentation finalized
- Pitch deck and live demo environment ready

### Deliverables

| Deliverable | Target Date |
|---|---|
| Security audit report and remediations | Jun 25 |
| Gas optimization pass (storage packing, calldata vs memory) | Jun 30 |
| Investor pitch deck | Jul 3 |
| Staging environment on RH Chain testnet | Jul 7 |
| Rehearsed live demo (< 5 min) | Jul 9 |

### KPIs

- Gas reduction: >= 15% vs Phase 1 baseline
- Zero critical or high findings post-remediation
- Demo reliability: 100% success rate across 10 dry runs

---

## Phase 3: London Founder House (Jul 10-12, 2026)

**Objective:** Showcase at Founder House London, secure partnerships, and gather feedback.

### Milestones

- Live demo delivered to Founder House attendees
- Partner meetings with at least 3 potential integrators
- Community feedback collected and triaged

### Deliverables

| Deliverable | Target Date |
|---|---|
| Live on-stage demo | Jul 10 |
| Partner meeting briefs (3+ meetings) | Jul 11-12 |
| Feedback synthesis document | Jul 14 |

### KPIs

- Partner conversations: >= 3
- Letters of intent or pilot commitments: >= 1
- Community sign-ups (GitHub stars, Discord members): >= 50

---

## Phase 4: Mainnet Alpha (Q3 2026)

**Objective:** Deploy to RH Chain mainnet and onboard the first pilot customer.

### Milestones

- Mainnet deployment with governance multisig
- First pilot partner processing real corporate actions on-chain
- Monitoring and alerting infrastructure operational
- Bug bounty program launched

### Deliverables

| Deliverable | Target Date |
|---|---|
| Mainnet deployment + verification | Aug 1 |
| Monitoring dashboard (Forta / custom) | Aug 15 |
| Pilot partner integration complete | Sep 15 |
| Bug bounty program launch | Sep 30 |

### KPIs

- Mainnet uptime: >= 99.9%
- Actions processed on mainnet: >= 10
- Mean time to finality per action: < 2 blocks
- Bug bounty submissions triaged within 48h

---

## Phase 5: Enterprise Launch (Q1 2027)

**Objective:** Launch enterprise-grade API, expand to multiple chains, and scale adoption.

### Milestones

- Enterprise REST/GraphQL API with authentication and rate limiting
- Multi-chain deployment (RH Chain, Arbitrum, Ethereum L1)
- SLA-backed service tier for institutional customers
- SDK packages for TypeScript and Python

### Deliverables

| Deliverable | Target Date |
|---|---|
| Enterprise API v1.0 | Jan 2027 |
| Multi-chain deployment (Arbitrum + Ethereum) | Feb 2027 |
| TypeScript and Python SDK packages | Feb 2027 |
| Enterprise SLA documentation and onboarding | Mar 2027 |

### KPIs

- Chains supported: >= 3
- Enterprise API latency (p99): < 200ms
- Active integrators: >= 5
- Monthly on-chain actions processed: >= 100

---

## Join the Team

We are building the future of on-chain corporate actions and welcome contributors at every level.

### How to Contribute

1. **Fork and clone** the repository.
2. **Pick an issue** labeled `good-first-issue` or `help-wanted` from the GitHub Issues tab.
3. **Follow the dev setup** in the project README to get your local environment running.
4. **Submit a PR** against `main` with a clear description of the change and linked issue.

### Contribution Guidelines

- All smart contract changes must include corresponding unit tests.
- Run `forge test -vvv` and `forge coverage --report summary` locally before submitting.
- Follow the existing Solidity style (NatSpec comments, explicit visibility, named return values).
- Security-sensitive changes require review from at least two maintainers.

### Areas We Need Help

| Area | Skills | Priority |
|---|---|---|
| Smart contract development | Solidity, Foundry | High |
| Security auditing | Slither, manual review, formal verification | High |
| Frontend / demo UI | React, ethers.js / viem | Medium |
| Documentation | Technical writing | Medium |
| Multi-chain deployment | Cross-chain messaging, bridge protocols | Medium |
| SDK development | TypeScript, Python | Low (Phase 5) |

### Get in Touch

- Open a GitHub Discussion for questions or ideas.
- Tag `@maintainers` in any issue for faster triage.
- Join the conversation in the Arbitrum Discord #builders channel.
