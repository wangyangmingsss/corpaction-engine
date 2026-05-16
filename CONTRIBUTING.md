# Contributing to CorpAction Engine

Thank you for your interest in contributing to CorpAction Engine.

## Development Setup

1. Clone the repository
2. Install Foundry: `curl -L https://foundry.paradigm.xyz | bash && foundryup`
3. Install contract dependencies: `cd packages/contracts && forge install`
4. Install service dependencies: `cd packages/services/<service> && npm install`

## Code Standards

### Smart Contracts (Solidity)
- Solidity 0.8.24+
- Follow Foundry formatting (`forge fmt`)
- 100% test coverage for all public/external functions
- Include NatSpec documentation
- Use custom errors instead of require strings where possible

### Off-Chain Services (TypeScript)
- TypeScript 5.x with strict mode
- Use structured JSON logging
- Handle errors explicitly — no silent catches

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Write tests for any new functionality
4. Ensure all tests pass: `make test`
5. Submit a pull request with a clear description

## Security

If you discover a security vulnerability, please report it privately.
See [SECURITY.md](SECURITY.md) for details.

## Join the Team

CorpAction Engine is building the infrastructure layer for tokenized equity lifecycle management. If you're interested in contributing beyond code, we're looking for:

### Areas of Need

| Area | Skills | Priority |
|------|--------|----------|
| **Smart Contract Security** | Solidity, formal verification, Slither/Mythril | High |
| **Cross-Chain Engineering** | LayerZero, Chainlink CCIP, bridge protocols | High |
| **DeFi Integration** | GMX, Uniswap V3, Aave, lending protocol mechanics | Medium |
| **DevRel / Documentation** | Technical writing, tutorial creation | Medium |
| **Frontend / Dashboard** | React, Next.js, ethers.js, data visualization | Medium |

### How to Get Involved

1. **Pick an open issue**: Check [Issues](https://github.com/wangyangmingsss/corpaction-engine/issues) for `good-first-issue` or `help-wanted` labels
2. **Join the discussion**: Comment on issues you're interested in before starting work
3. **Propose new ideas**: Open a feature request if you see an opportunity we've missed

### Buildathon → Founder House Pipeline

Top contributors during the Buildathon phase (May 25 - Jun 14, 2026) will be considered for the London Founder House cohort (Jul 10-12, 2026). This is a direct path from open-source contribution to startup co-founding.
