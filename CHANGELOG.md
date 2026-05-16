# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2026-05-16

### Added
- **AI Agent Classification**: Hybrid rule+LLM classifier with Anthropic Claude integration (`CorpActionAgent`, `HybridClassifier`)
- **Chainlink Integration**: `ChainlinkPriceAdapter` for automated delisting price feeds with staleness checks
- **LayerZero Integration**: `CrossChainNotifier` and `CrossChainReceiver` for multi-chain corporate action broadcasting
- **Demo Scripts**: 6 end-to-end lifecycle demo scripts (AAPL dividend, NVDA split, FullDividendDemo)
- **Documentation**: ROBINHOOD-CHAIN-INTEGRATION.md, DEMO_WALKTHROUGH.md, ECONOMICS.md, ERC-8056-IMPLEMENTATION-NOTES.md, ROADMAP.md, COMMUNITY.md
- **Security**: Slither report, coverage report (94.2%), comprehensive threat model (10 attack vectors)
- **GitHub Project Management**: 15 issues with labels, project board

### Changed
- README: Comprehensive upgrade with "Built for Robinhood Chain", "AI-Powered Classification", "Why Arbitrum?", ecosystem integrations
- CI: Improved reproducibility with explicit forge install, coverage reporting
- Docker Compose: Added AI agent environment variables
- Smart Contracts table: Expanded from 11 to 14 contracts
- On-Chain Demo: Updated transaction table with Status column showing EXECUTED + CLAIMED

### Improved
- CONTRIBUTING.md: Added "Join the Team" section with areas of need
- .env.example: Added AI agent configuration variables
- Repository structure: New directories for integrations, agent, demo scripts, security docs

## [1.0.0] - 2026-05-15

### Added
- Core smart contracts: ActionRegistry, ValidatorManager, TimelockController
- Executor contracts: DividendDistributor, SplitExecutor, MergerHandler, SpinoffExecutor, DelistingManager, TickerMigrator
- Verification: AttestationRegistry
- Fee management: FeeCollector
- Off-chain services: Ingestion (EDGAR, EOD Historical, Polygon), Processor, Validator
- TypeScript SDK for integrators
- Database schema (PostgreSQL)
- Docker Compose production stack
- CI/CD pipelines (GitHub Actions)
- Monitoring (Prometheus + Grafana)
- Comprehensive test suite (unit, fuzz, integration)
