# Security Threat Model

## Document Purpose

This threat model identifies, categorizes, and proposes mitigations for security risks in the CorpAction Engine system. It covers the full stack: on-chain smart contracts, off-chain services (ingestion, processing, validation), and the interfaces between them.

---

## System Architecture Overview

```
                    External Data Sources
                    (SEC EDGAR, DTCC, APIs)
                            |
                    [Ingestion Service]
                            |
                    [Processor Service]
                            |
              [Validator Quorum (M-of-N)]
                            |
                    [On-Chain Contracts]
         ActionRegistry -> TimelockController -> Executors
                            |
                    [Token Holders / DeFi]
```

### Trust Boundaries

| Boundary | Components Inside | Trust Level |
|---|---|---|
| **B1: External Data** | SEC EDGAR, DTCC, Polygon, EOD Historical, Alpha Vantage, Bloomberg | Untrusted (verified by multi-source correlation) |
| **B2: Off-Chain Services** | Ingestion, Processor, Validator nodes | Semi-trusted (controlled infrastructure, not on-chain) |
| **B3: On-Chain Contracts** | ActionRegistry, Executors, ValidatorManager | Trusted (immutable after deployment, auditable) |
| **B4: End Users** | Token holders, DeFi protocols, claimants | Untrusted (adversarial by default) |

---

## Attack Vectors and Mitigations

### 1. Validator Collusion

**Threat:** A quorum of validators conspire to propose and validate a fraudulent corporate action (e.g., a fake dividend that drains the USDG pool, or a malicious merger that liquidates holder positions).

**Severity:** CRITICAL

**Attack path:**
1. Compromised or colluding validators propose a fraudulent ActionIntent
2. They sign validations to reach quorum
3. After timelock, the action executes and causes financial harm

**Mitigations:**
- Severity-based quorum thresholds: high-severity actions (mergers, delistings) require 4-of-5 validator signatures
- Mandatory timelocks (24-48h for high-severity) provide a window for detection and emergency pause
- Any single honest validator can trigger `emergencyPause()` to halt all execution
- Action reversal requires 5-of-5 (all validators), preventing a colluding subset from covering their tracks
- Source attestation with EIP-712 typed data signing creates a cryptographic audit trail linking every action to a verifiable real-world filing
- On-chain events enable external monitoring and alerting

**Residual risk:** If all validators are compromised simultaneously and no external monitoring is in place, a fraudulent action could execute after the timelock expires.

---

### 2. Oracle / Data Source Manipulation

**Threat:** An attacker manipulates or spoofs data from external sources (SEC EDGAR, DTCC feeds, financial APIs) to trigger an incorrect corporate action.

**Severity:** HIGH

**Attack path:**
1. Attacker compromises or spoofs a data source API
2. Ingestion service receives fabricated corporate action data
3. Processor builds and submits a fraudulent ActionIntent
4. Validators, checking the same compromised source, validate the intent

**Mitigations:**
- Multi-source correlation: EventDeduplicator requires confirmation from multiple independent sources before marking an event as high-confidence
- ISIN-based deduplication with composite keys prevents duplicate submission
- EventClassifier uses item-level 8-K parsing (not just filing type), reducing false classifications
- Validator nodes perform independent source verification via `SourceVerifier`, which dispatches to source-specific verification logic
- Confidence scoring: low-confidence events (single-source) are flagged and held in PENDING state
- RSS feed fallback for EDGAR provides a secondary channel if the primary API is compromised

**Residual risk:** If a data source (especially SEC EDGAR) is compromised at the source level, multiple validators may independently confirm the same false data. Mitigation depends on cross-source validation.

---

### 3. Front-Running

**Threat:** An attacker observes a pending corporate action proposal in the mempool and front-runs it by acquiring or disposing of tokens before the action takes effect.

**Severity:** MEDIUM

**Attack path:**
1. Attacker monitors the mempool for `proposeAction()` transactions
2. Before the proposal is mined, attacker buys tokens (for dividends) or sells tokens (for delistings)
3. After the action executes, attacker profits from the information asymmetry

**Mitigations:**
- Snapshot-based eligibility: Dividend distributions use `snapshotBlock` to determine holder balances at a specific past block, not the current block
- Timelock delay: The mandatory waiting period between proposal and execution means the token price likely already reflects the corporate action by the time execution occurs (information is public on-chain at proposal time)
- Record date enforcement: ActionIntents include a `recordDate` that determines eligibility, independent of when the on-chain transaction is mined
- Private mempool options: On Arbitrum L2, transactions can be submitted through the sequencer, reducing mempool visibility

**Residual risk:** Front-running the `proposeAction()` transaction itself remains possible on L2 if the attacker has sequencer-level visibility. However, the financial impact is limited because the proposal merely publishes information that is already publicly available from SEC filings.

---

### 4. Merkle Proof Forgery

**Threat:** An attacker fabricates a Merkle proof to claim dividends or cash-in-lieu payments they are not entitled to.

**Severity:** HIGH

**Attack path:**
1. Attacker constructs a forged Merkle proof for a leaf containing their address and a large amount
2. Attacker calls `claimDividend()` or `claimCashInLieu()` with the forged proof

**Mitigations:**
- Merkle roots are set by the ActionRegistry (trusted contract), not by external callers
- OpenZeppelin `MerkleProof.verify()` is used for cryptographic verification -- forging a valid proof requires breaking the hash function (computationally infeasible)
- Leaf encoding: `keccak256(abi.encodePacked(holder, amount))` binds the proof to both the address and the exact amount
- Double-claim prevention: `claimed[intentId][msg.sender]` mapping prevents replay

**Residual risk:** If the off-chain Merkle tree is constructed with incorrect data (e.g., wrong holder balances), legitimate holders may receive incorrect amounts. This is an integrity risk in the Processor service, not a cryptographic risk.

---

### 5. Reentrancy Attacks

**Threat:** An attacker exploits reentrancy during token transfers in claim functions to drain funds.

**Severity:** HIGH

**Attack path:**
1. Attacker deploys a malicious contract with a `receive()` / fallback function
2. During `claimDividend()` or `claimCashInLieu()`, the token transfer calls back into the claim function
3. The attacker re-enters and claims multiple times before the `claimed` flag is set

**Mitigations:**
- `ReentrancyGuardUpgradeable` from OpenZeppelin is applied to all claim functions (`nonReentrant` modifier)
- Checks-Effects-Interactions pattern: `claimed[intentId][msg.sender] = true` is set before the token transfer
- `SafeERC20.safeTransfer()` is used for all token transfers, preventing issues with non-standard ERC-20 implementations

**Residual risk:** Effectively zero. The combination of `ReentrancyGuard`, checks-effects-interactions, and `SafeERC20` addresses all known reentrancy vectors.

---

### 6. Unauthorized Upgrade

**Threat:** An attacker upgrades a UUPS proxy contract to a malicious implementation, gaining control over all funds and state.

**Severity:** CRITICAL

**Attack path:**
1. Attacker gains access to the `UPGRADER_ROLE` on ActionRegistry
2. Attacker deploys a malicious implementation contract
3. Attacker calls `upgradeTo()` to replace the proxy implementation

**Mitigations:**
- `UPGRADER_ROLE` is restricted to the deployer / multisig wallet
- Production configuration requires 4-of-5 validator approval for upgrades
- 72-hour timelock before upgrade activation
- All upgrades emit on-chain events for monitoring
- `_authorizeUpgrade()` in executor contracts restricts upgrades to the ActionRegistry address only

**Residual risk:** If the deployer/multisig private key is compromised and the timelock is bypassed (e.g., via a bug in the timelock contract), the proxy could be upgraded maliciously.

---

### 7. Denial of Service (Emergency Pause Abuse)

**Threat:** A single malicious or compromised validator repeatedly triggers `emergencyPause()`, halting all system operations.

**Severity:** MEDIUM

**Attack path:**
1. Compromised validator calls `emergencyPause()`
2. All pending and new executions are halted
3. Resume requires 4-of-5 supermajority, which takes time to coordinate
4. Attacker repeatedly pauses after each resume

**Mitigations:**
- Resume requires supermajority (4-of-5), so the system can recover without the malicious validator
- Validator removal: `ValidatorManager` allows the admin to remove compromised validators
- Monitoring: `EmergencyPaused` events trigger immediate alerts
- The pause mechanism is intentionally asymmetric (easy to pause, hard to resume) because the cost of a false pause is much lower than the cost of a missed pause during a real emergency

**Residual risk:** Between pause and resume, legitimate corporate actions are delayed. This is an acceptable trade-off for safety.

---

### 8. Timelock Bypass

**Threat:** An attacker finds a way to execute a queued action before the timelock has expired.

**Severity:** HIGH

**Attack path:**
1. Attacker manipulates block timestamps or finds a code path that skips the timelock check
2. A high-severity action (merger, delisting) executes without the mandatory waiting period

**Mitigations:**
- `executeAction()` explicitly checks `block.timestamp < _executionTime[intentId]` and reverts with `TimelockNotExpired`
- `TimelockController` is a separate contract, reducing the chance of a single-contract bypass
- Queue TTL expiration: queued actions that exceed the `queuedTTL` (default 7 days) are automatically expired and cannot be executed
- Block timestamp manipulation on Arbitrum L2 is constrained by the sequencer and L1 finality

**Residual risk:** A bug in the Solidity compiler or EVM implementation could theoretically bypass the timestamp check. This is mitigated by comprehensive testing (100+ tests including invariant tests that verify the state machine never transitions backward).

---

### 9. Private Key Compromise (Validator)

**Threat:** An attacker steals the private key of one or more validator nodes.

**Severity:** HIGH (single key) / CRITICAL (multiple keys)

**Attack path:**
1. Attacker compromises validator infrastructure (server breach, phishing, supply chain attack)
2. Attacker signs fraudulent proposals or validations using the stolen key

**Mitigations:**
- Severity-based quorum: compromising a single validator is insufficient for any action type (production config: minimum 2-of-3)
- Validator heartbeat monitoring: offline validators trigger alerts within 5 minutes
- Key rotation: validators can be added/removed via `ValidatorManager` without redeploying contracts
- Hardware security modules (HSMs) recommended for production validator key storage
- EIP-712 typed data signing provides structured signing that prevents blind signing attacks

**Residual risk:** If multiple validator keys are compromised simultaneously (e.g., shared infrastructure), the quorum threshold may be reached. This is mitigated by requiring validators to operate on independent infrastructure.

---

### 10. Stale or Expired Action Execution

**Threat:** An outdated corporate action that is no longer valid in the real world gets executed on-chain because it was queued before conditions changed.

**Severity:** MEDIUM

**Attack path:**
1. A corporate action is proposed and queued
2. In the real world, the action is amended or cancelled (e.g., a merger is called off)
3. The on-chain queued action is still executable after the timelock

**Mitigations:**
- Intent TTL: proposed actions expire if not validated within `intentTTL`
- Queue TTL: queued actions expire if not executed within `queuedTTL` (default 7 days)
- Cancellation: any validator can call `cancelAction()` on actions in PROPOSED or QUEUED state
- Continuous monitoring: the ingestion service monitors for DTCC seev.044 reversal notifications and seev.039 cancellations
- `ActionCancelled` events enable downstream protocols to revert any preparations

**Residual risk:** If no validator notices the real-world cancellation before the on-chain timelock expires, the stale action could execute. This window is bounded by the queue TTL.

---

## Severity Ratings Summary

| # | Threat | Severity | Likelihood | Impact | Mitigated By |
|---|---|---|---|---|---|
| 1 | Validator Collusion | CRITICAL | Low | Complete fund drainage | Quorum thresholds, timelocks, emergency pause, reversal, attestation |
| 2 | Oracle/Data Manipulation | HIGH | Medium | Incorrect action execution | Multi-source correlation, validator verification, confidence scoring |
| 3 | Front-Running | MEDIUM | High | Unfair profit extraction | Snapshot blocks, record dates, timelocks, L2 sequencer |
| 4 | Merkle Proof Forgery | HIGH | Very Low | Unauthorized fund claims | Cryptographic verification, leaf binding, double-claim prevention |
| 5 | Reentrancy | HIGH | Very Low | Fund drainage via re-entry | ReentrancyGuard, checks-effects-interactions, SafeERC20 |
| 6 | Unauthorized Upgrade | CRITICAL | Low | Complete system takeover | UPGRADER_ROLE, multisig, 72h timelock, event monitoring |
| 7 | Emergency Pause Abuse | MEDIUM | Medium | Denial of service | Supermajority resume, validator removal, monitoring |
| 8 | Timelock Bypass | HIGH | Very Low | Premature high-severity execution | Explicit timestamp checks, separate controller, invariant tests |
| 9 | Private Key Compromise | HIGH-CRITICAL | Medium | Fraudulent signatures | Quorum, heartbeat, key rotation, HSMs, independent infrastructure |
| 10 | Stale Action Execution | MEDIUM | Medium | Outdated action executed | Intent TTL, queue TTL, cancellation, reversal monitoring |

---

## Residual Risks

The following risks remain after all mitigations are applied. They represent the accepted risk profile of operating CorpAction Engine.

### 1. Systemic Data Source Compromise

If a primary data source (SEC EDGAR) is compromised at the institutional level, all validators may independently confirm the same false data. This is a systemic risk that no single system can fully mitigate.

**Acceptance rationale:** SEC EDGAR compromise would affect the entire financial system, not just CorpAction Engine. The multi-source correlation reduces (but does not eliminate) this risk.

### 2. L2 Sequencer Centralization

Robinhood Chain (Arbitrum L2) relies on a centralized sequencer. The sequencer could theoretically censor transactions, reorder them, or manipulate timestamps within bounds.

**Acceptance rationale:** This is a platform-level risk shared by all applications on the chain. Arbitrum's fraud proof mechanism provides L1 security guarantees, and the 7-day challenge window allows detection of sequencer misbehavior.

### 3. Smart Contract Bugs

Despite 100+ tests, fuzz testing, and invariant testing, undiscovered bugs may exist in the smart contracts.

**Acceptance rationale:** The UUPS proxy pattern allows contract upgrades to patch discovered bugs. The emergency pause mechanism provides an immediate stop-gap. A formal audit is recommended before mainnet deployment.

### 4. Off-Chain Service Availability

The ingestion, processor, and validator services are centralized off-chain components. Downtime in these services means corporate actions are not detected or processed.

**Acceptance rationale:** Docker-compose deployment with health checks, Prometheus monitoring, and Grafana alerting reduce downtime risk. The system fails safely -- missed actions can be manually proposed once services recover. No funds are at risk from service downtime.

---

## Recommendations

| Priority | Recommendation | Status |
|---|---|---|
| P0 | Formal smart contract audit before mainnet deployment | Planned for Q3 2026 |
| P0 | HSM-based key management for production validators | Planned |
| P1 | Bug bounty program for contract vulnerabilities | Planned post-audit |
| P1 | Geographic distribution of validator nodes | Planned for mainnet |
| P1 | Automated real-world action cancellation detection (DTCC seev.044) | Implemented (ingestion service) |
| P2 | Decentralized validator set with economic staking | Future roadmap |
| P2 | Formal verification of MultiplierMath and state machine transitions | Under consideration |
| P2 | Multi-chain deployment for redundancy | Future roadmap |
| P3 | Zero-knowledge proof of source data verification | Research phase |
