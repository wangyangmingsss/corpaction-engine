# CorpAction Engine - Community Engagement Plan

> Building in public: announcements, showcases, and feedback loops for the CorpAction Engine project.

---

## Twitter/X Announcements

### Tweet 1 - Project Launch

```
We just open-sourced CorpAction Engine -- on-chain corporate actions processing built on ERC-8056.

Stock splits, dividends, and mergers executed as verifiable smart contract workflows.

Built with @foundaborhood @arbitrum

github.com/[org]/corpaction-engine
```

### Tweet 2 - Buildathon Entry

```
Entering the Buildathon (May 25 - Jun 14) with CorpAction Engine.

What we're building:
- ERC-8056 compliant action lifecycle
- Fuzz-tested entitlement calculations
- Gas-optimized for RH Chain

Follow along as we ship daily.

#Buildathon2026 #DeFi #RWA
```

### Tweet 3 - Test Coverage Milestone

```
CorpAction Engine test suite update:

- 80%+ code coverage
- Fuzz tests catching edge cases in entitlement math
- Zero high-severity Slither findings

All open source. All verifiable.

Reproducible CI: forge build -> forge test -> forge coverage
```

### Tweet 4 - Founder House Preview

```
Heading to London Founder House (Jul 10-12) with a live demo of on-chain corporate actions.

Real stock splits. Real dividend distributions. Real smart contracts.

If you're building in RWA / tokenized securities, let's talk.

DMs open.
```

### Tweet 5 - Post Founder House Recap

```
Just wrapped London Founder House.

Key takeaways from showing CorpAction Engine:
- Institutional interest in on-chain corporate actions is real
- ERC-8056 resonates with builders who understand the gap
- Next up: mainnet alpha on RH Chain

Thanks to everyone who stopped by the demo.
```

---

## Arbitrum Discord #builders Showcase Post

### Template

```
--- Project Showcase ---

Project: CorpAction Engine
Category: RWA / Tokenized Securities Infrastructure
Stage: Buildathon / Pre-mainnet

What it does:
CorpAction Engine processes corporate actions (stock splits, dividends, mergers)
entirely on-chain using the ERC-8056 standard. It provides a verifiable,
auditable lifecycle from action creation through entitlement calculation
and execution.

Tech stack:
- Solidity (Foundry)
- ERC-8056 (Corporate Action Token Standard)
- Target chain: RH Chain (EVM-compatible), with Arbitrum support planned

What we're looking for:
- Feedback on our ERC-8056 implementation approach
- Security reviewers familiar with financial smart contracts
- Partners building in tokenized securities / RWA space

Links:
- GitHub: [repo link]
- Docs: [docs link]
- Demo: [demo walkthrough link]

Happy to answer any questions or jump on a call to walk through the architecture.
```

---

## Ethereum Magicians - ERC-8056 Implementation Feedback

### Forum Post Template

**Title:** ERC-8056 Implementation Report: CorpAction Engine

**Category:** ERCs / Token Standards

**Body:**

```
Hi all,

We have been building an implementation of ERC-8056 (Corporate Action Token Standard)
called CorpAction Engine. Sharing our experience and requesting feedback from the
community.

## Implementation Summary

We implemented the full ERC-8056 lifecycle:
1. Action creation and registration (ActionRegistry)
2. Entitlement calculation (EntitlementCalculator)
3. Execution and settlement (CorporateActionEngine)

Supported action types: stock splits, cash dividends, stock dividends, mergers.

## Design Decisions We Want Feedback On

1. **Action state machine**: We use a linear state progression
   (Created -> Approved -> Executed -> Settled). Should we support
   branching states (e.g., Disputed, Cancelled)?

2. **Entitlement precision**: We use 18-decimal fixed-point arithmetic
   for fractional entitlements. Is this sufficient for all corporate
   action types, or should we support configurable precision?

3. **Gas optimization vs. readability**: We chose storage packing in
   the ActionRegistry. The gas savings are significant (~15%), but
   the code is harder to audit. Thoughts on the right tradeoff?

4. **Multi-chain considerations**: Our current design assumes single-chain
   execution. For cross-chain corporate actions, should the standard
   define a canonical chain, or support parallel execution with
   reconciliation?

## What We Learned

- Fuzz testing is essential for entitlement math -- we caught 3 rounding
  bugs that unit tests missed.
- The ERC-8056 spec leaves room for interpretation on settlement finality.
  We would appreciate more guidance in the standard.
- Gas costs for batch processing scale linearly. We are exploring
  Merkle-based batch claims as an alternative.

## Links

- Implementation: [GitHub repo]
- Test results: [CI link]
- Documentation: [docs link]

Looking forward to the discussion.
```

---

## GitHub Release v0.1.0 Notes Template

### Release: v0.1.0 - Buildathon Release

```markdown
# CorpAction Engine v0.1.0

**Buildathon Release** | June 14, 2026

The first public release of CorpAction Engine, an on-chain corporate actions
processing system built on the ERC-8056 standard.

## Highlights

- Full ERC-8056 corporate action lifecycle (create, approve, execute, settle)
- Stock split, cash dividend, stock dividend, and merger support
- Gas-optimized ActionRegistry with storage packing
- Comprehensive test suite (unit + fuzz) with 80%+ coverage

## Contracts

| Contract | Description |
|---|---|
| CorporateActionEngine.sol | Core orchestrator for action lifecycle |
| ActionRegistry.sol | On-chain registry of corporate action definitions |
| EntitlementCalculator.sol | Fractional entitlement math (18-decimal precision) |

## Getting Started

```bash
git clone --recurse-submodules [repo-url]
cd corpaction-engine/packages/contracts
forge install
forge build --sizes
forge test -vvv
```

## Known Limitations

- Single-chain execution only (multi-chain planned for Phase 5)
- No batch claim optimization yet (Merkle-based claims in backlog)
- Gas report baseline established but not yet fully optimized

## What's Next

See the [ROADMAP](docs/ROADMAP.md) for the full plan through mainnet and beyond.

## Contributors

Thanks to everyone who contributed to this release.

---

**Full Changelog**: [link to diff]
```
