# CorpAction Engine — System Architecture

## Overview

CorpAction Engine is a four-layer system for automating corporate actions on tokenized equities.

## Layer 1: Data Ingestion

**Components:** SEC EDGAR Monitor, Financial Data API Adapters, Event Deduplicator

- Polls SEC EDGAR every 60s during market hours, 5 min off-hours
- Supports 8-K, 14A, S-4, SC TO-T, 25-NSE filing types
- Cross-validates with EOD Historical Data, Polygon.io
- Deduplicates using composite keys: (ticker/ISIN) + actionType + effectiveDate

## Layer 2: Normalization

**Components:** Event Classifier, ISO 20022 Mapper, ActionIntent Builder

- Rule-based classification (deterministic, auditable)
- Maps to ISO 20022 corporate action message types (seev.031-seev.044)
- Builds ActionIntent structs with ABI-encoded parameters
- Computes Merkle trees for dividend/spinoff distributions

## Layer 3: On-Chain Execution

**Components:** ActionRegistry, Executor Contracts

- ActionRegistry manages the full lifecycle: PROPOSED → VALIDATED → QUEUED → EXECUTING → EXECUTED
- Executor contracts handle type-specific logic:
  - DividendDistributor: Merkle-based USDC pull distribution
  - SplitExecutor: ERC-8056 multiplier updates
  - MergerHandler: Cash, stock-for-stock, and hybrid mergers
  - DelistingManager: 5-phase delisting process
  - SpinoffExecutor: New token deployment + distribution
  - TickerMigrator: Symbol/address migration

## Layer 4: Attestation & Governance

**Components:** AttestationRegistry, ValidatorManager

- M-of-N multi-signature validation with severity-based quorums
- Time-lock enforcement (1h-48h based on action severity)
- Emergency circuit breaker (any validator can pause)
- Source attestation linking on-chain actions to off-chain sources

## Security Architecture

- UUPS proxy upgrade pattern with 72h time-lock
- No single-signer execution path
- Content hashing of source documents
- Comprehensive event logging for audit trail
