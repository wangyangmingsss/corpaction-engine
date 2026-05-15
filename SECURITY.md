# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in CorpAction Engine, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email: security@corpaction.engine (or use GitHub's private vulnerability reporting feature)

## Scope

The following are in scope:
- Smart contract vulnerabilities (reentrancy, access control, arithmetic, etc.)
- Off-chain service vulnerabilities (injection, authentication bypass, etc.)
- Cryptographic issues (signature malleability, replay attacks, etc.)

## Security Measures

- Multi-signature validation (M-of-N) for all corporate actions
- Time-lock enforcement for high-severity actions
- Emergency circuit breaker (any validator can pause)
- Source attestation with cryptographic proof
- UUPS proxy upgrade pattern with 72h time-lock
- Comprehensive test coverage with fuzz and invariant testing
