import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert';
import { SourceVerifier } from '../src/SourceVerifier';

describe('SourceVerifier', () => {
  let verifier: SourceVerifier;

  beforeEach(() => {
    verifier = new SourceVerifier();
  });

  it('verifies EDGAR source when eventId contains accession number pattern', async () => {
    // Stub global fetch to simulate a successful EDGAR response
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () => ({
      ok: true,
      text: async () => '<filing><accession>0001234567-24-000001</accession></filing>',
      status: 200,
    })) as any;

    try {
      const result = await verifier.verify(
        'EDGAR:0001234567-24-000001',
        0, // DIVIDEND
        'some-params'
      );

      assert.strictEqual(result.verified, true);
      assert.ok(result.details.includes('Filing verified'));
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it('returns verified=false when EDGAR filing fetch fails', async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () => ({
      ok: false,
      status: 404,
      text: async () => 'Not Found',
    })) as any;

    try {
      const result = await verifier.verify(
        'EDGAR:0001234567-24-000099',
        1, // FORWARD_SPLIT
        ''
      );

      assert.strictEqual(result.verified, false);
      assert.ok(result.details.includes('404'));
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it('falls back to content hash verification for non-EDGAR sources', async () => {
    // eventId without an accession number pattern
    const result = await verifier.verify(
      'POLYGON:evt_12345',
      0, // DIVIDEND
      'some-action-params-data'
    );

    assert.strictEqual(result.verified, true);
    assert.ok(result.details.includes('Params hash verified'));
  });

  it('returns verified=true with no-source message when no params and no accession', async () => {
    const result = await verifier.verify(
      'UNKNOWN:no-accession',
      0,
      ''
    );

    assert.strictEqual(result.verified, true);
    assert.ok(result.details.includes('No source-specific verification'));
  });

  it('returns verified=false for unknown action types', async () => {
    const result = await verifier.verify('test:1', 999, 'params');

    assert.strictEqual(result.verified, false);
    assert.ok(result.details.includes('Unknown actionType'));
  });

  it('computeContentHash produces consistent SHA-256 hashes', () => {
    const hash1 = verifier.computeContentHash('hello world');
    const hash2 = verifier.computeContentHash('hello world');
    assert.strictEqual(hash1, hash2);
    assert.strictEqual(hash1.length, 64); // SHA-256 hex = 64 chars

    const hash3 = verifier.computeContentHash('different data');
    assert.notStrictEqual(hash1, hash3);
  });
});
