# Changelog

All notable changes to this project will be documented in this file.

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
