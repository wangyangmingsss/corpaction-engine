# Security Model

## Multi-Signature Validation

| Severity | Actions | Quorum |
|----------|---------|--------|
| Low | Ticker change, metadata update | 2-of-3 |
| Medium | Dividend, stock split | 3-of-5 |
| High | Merger, delisting, liquidation | 4-of-5 + time-lock |

## Time-Lock Enforcement

| Action Type | Duration |
|-------------|----------|
| Dividend | 1 hour |
| Stock Split | 2 hours |
| Merger/Acquisition | 24 hours |
| Delisting/Liquidation | 48 hours |
| Contract Upgrade | 72 hours |

## Emergency Circuit Breaker

- Any single validator can trigger `emergencyPause()`
- All pending and new executions halted immediately
- Resume requires supermajority (4-of-5) via `emergencyResume()`

## Source Attestation

Every ActionIntent includes:
- Source identifier (SEC EDGAR URL, DTCC event ID)
- SHA-256 content hash of source document
- Ingestion timestamp
- Block number at submission
- Validator signatures confirming independent verification

## Upgrade Security

- UUPS proxy pattern from OpenZeppelin
- Upgrade authorization: 4-of-5 validators
- 72-hour time-lock before upgrade activation
- All upgrades emit events for transparency
