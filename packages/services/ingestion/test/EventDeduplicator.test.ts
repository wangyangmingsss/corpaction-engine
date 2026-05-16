import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert';
import { EventDeduplicator } from '../src/dedup/EventDeduplicator';
import { RawCorporateActionEvent } from '../src/sources/ICorporateActionSource';

function createLoggerStub() {
  return {
    info: (..._a: unknown[]) => {},
    warn: (..._a: unknown[]) => {},
    error: (..._a: unknown[]) => {},
    debug: (..._a: unknown[]) => {},
  };
}

function makeEvent(overrides: Partial<RawCorporateActionEvent> = {}): RawCorporateActionEvent {
  return {
    sourceType: 'SEC_EDGAR',
    sourceId: 'EDGAR:001',
    contentHash: 'hash_aaa',
    ticker: 'AAPL',
    eventType: 'DIVIDEND',
    rawData: { effective_date: '2024-06-15', amount: 0.5 },
    detectedAt: new Date('2024-06-01'),
    ...overrides,
  };
}

describe('EventDeduplicator', () => {
  let dedup: EventDeduplicator;

  beforeEach(() => {
    dedup = new EventDeduplicator(createLoggerStub() as any);
  });

  it('single event passes through as unique', () => {
    const event = makeEvent();
    const result = dedup.deduplicate([event]);

    assert.strictEqual(result.unique.length, 1);
    assert.strictEqual(result.duplicates.length, 0);
    assert.strictEqual(result.conflicts.length, 0);
    assert.strictEqual(result.unique[0].ticker, 'AAPL');
  });

  it('duplicate events with same ticker+type+date are deduplicated', () => {
    const event1 = makeEvent({ sourceType: 'SEC_EDGAR', sourceId: 'E:1', contentHash: 'same_hash' });
    const event2 = makeEvent({ sourceType: 'SEC_EDGAR', sourceId: 'E:2', contentHash: 'same_hash' });

    const result = dedup.deduplicate([event1, event2]);

    assert.strictEqual(result.unique.length, 1);
    assert.strictEqual(result.duplicates.length, 1);
    assert.strictEqual(result.conflicts.length, 0);
  });

  it('conflicting events with different critical params are flagged', () => {
    const event1 = makeEvent({
      sourceType: 'SEC_EDGAR',
      sourceId: 'E:1',
      contentHash: 'hash_1',
      rawData: { effective_date: '2024-06-15', amount: 0.5 },
    });
    const event2 = makeEvent({
      sourceType: 'POLYGON',
      sourceId: 'P:1',
      contentHash: 'hash_2',
      rawData: { effective_date: '2024-06-15', amount: 2.0 },
    });

    const result = dedup.deduplicate([event1, event2]);

    assert.strictEqual(result.conflicts.length, 1);
    assert.ok(result.conflicts[0].reason.includes('Dividend amount mismatch'));
    // Conflict should set confidence to LOW
    const key = 'AAPL:DIVIDEND:2024-06-15';
    assert.strictEqual(result.confidenceLevels.get(key), 'LOW');
  });

  it('multiple agreeing sources increase confidence to HIGH', () => {
    const event1 = makeEvent({
      sourceType: 'SEC_EDGAR',
      sourceId: 'E:1',
      contentHash: 'hash_x',
      rawData: { effective_date: '2024-06-15', amount: 0.5 },
    });
    const event2 = makeEvent({
      sourceType: 'POLYGON',
      sourceId: 'P:1',
      contentHash: 'hash_y',
      rawData: { effective_date: '2024-06-15', amount: 0.5 },
    });

    const result = dedup.deduplicate([event1, event2]);

    // Same amount so no critical conflict -- non-critical difference treated as duplicate
    assert.strictEqual(result.unique.length, 1);
    assert.strictEqual(result.duplicates.length, 1);
    // Two different sources => confidence promoted to HIGH
    const key = 'AAPL:DIVIDEND:2024-06-15';
    assert.strictEqual(result.confidenceLevels.get(key), 'HIGH');
  });

  it('single-source event starts with PENDING confidence', () => {
    const event = makeEvent();
    dedup.deduplicate([event]);

    const confidence = dedup.getConfidence(event);
    assert.strictEqual(confidence, 'PENDING');
  });

  it('reset clears all internal state', () => {
    const event = makeEvent();
    dedup.deduplicate([event]);
    dedup.reset();

    // After reset, same event should be treated as new
    const result = dedup.deduplicate([event]);
    assert.strictEqual(result.unique.length, 1);
    assert.strictEqual(result.duplicates.length, 0);
  });
});
