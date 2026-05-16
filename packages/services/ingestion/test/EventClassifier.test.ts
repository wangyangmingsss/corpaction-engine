import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert';
import { EventClassifier } from '../src/classifier/EventClassifier';
import { RawCorporateActionEvent } from '../src/sources/ICorporateActionSource';

function createLoggerStub() {
  return {
    info: (..._a: unknown[]) => {},
    warn: (..._a: unknown[]) => {},
    error: (..._a: unknown[]) => {},
    debug: (..._a: unknown[]) => {},
  };
}

function makeEvent(overrides: Partial<RawCorporateActionEvent>): RawCorporateActionEvent {
  return {
    sourceType: 'TEST',
    sourceId: 'test:1',
    contentHash: 'abc123',
    ticker: 'AAPL',
    rawData: {},
    detectedAt: new Date(),
    ...overrides,
  };
}

describe('EventClassifier', () => {
  let classifier: EventClassifier;

  beforeEach(() => {
    classifier = new EventClassifier(createLoggerStub() as any);
  });

  it('classifies a dividend event with amount and payment date as HIGH confidence', () => {
    const event = makeEvent({
      eventType: 'DIVIDEND',
      rawData: { dividend: 1.5, pay_date: '2024-06-15', ex_date: '2024-06-01' },
    });

    const result = classifier.classify(event);
    assert.ok(result);
    assert.strictEqual(result.actionType, 'DIVIDEND');
    assert.strictEqual(result.confidence, 'HIGH');
    assert.ok(result.signals.includes('amount_present'));
    assert.strictEqual(result.params.amount, 1.5);
    assert.strictEqual(result.params.payDate, '2024-06-15');
  });

  it('classifies a dividend without amount as MEDIUM confidence', () => {
    const event = makeEvent({
      eventType: 'DIVIDEND',
      rawData: {},
    });

    const result = classifier.classify(event);
    assert.ok(result);
    assert.strictEqual(result.actionType, 'DIVIDEND');
    assert.strictEqual(result.confidence, 'MEDIUM');
    assert.ok(result.signals.includes('amount_missing'));
  });

  it('classifies a forward split with ratio', () => {
    const event = makeEvent({
      eventType: 'SPLIT',
      rawData: { ratio: '4:1' },
    });

    const result = classifier.classify(event);
    assert.ok(result);
    assert.strictEqual(result.actionType, 'FORWARD_SPLIT');
    assert.strictEqual(result.confidence, 'HIGH');
    assert.strictEqual(result.params.numerator, 4);
    assert.strictEqual(result.params.denominator, 1);
    assert.strictEqual(result.params.isReverse, false);
  });

  it('classifies a reverse split correctly', () => {
    const event = makeEvent({
      eventType: 'SPLIT',
      rawData: { ratio: '1:10' },
    });

    const result = classifier.classify(event);
    assert.ok(result);
    assert.strictEqual(result.actionType, 'REVERSE_SPLIT');
    assert.strictEqual(result.params.isReverse, true);
    assert.strictEqual(result.params.numerator, 1);
    assert.strictEqual(result.params.denominator, 10);
  });

  it('classifies a merger registration event', () => {
    const event = makeEvent({
      eventType: 'MERGER_REGISTRATION',
      rawData: { cash_per_share: 50.0, exchange_ratio: 0.5 },
    });

    const result = classifier.classify(event);
    assert.ok(result);
    assert.strictEqual(result.actionType, 'MERGER_HYBRID');
    assert.strictEqual(result.confidence, 'MEDIUM');
  });

  it('returns null for unclassifiable event', () => {
    const event = makeEvent({
      eventType: 'TOTALLY_UNKNOWN_TYPE',
      rawData: { some: 'data' },
    });

    const result = classifier.classify(event);
    assert.strictEqual(result, null);
  });

  it('detects dividend signals from rawData keywords when eventType is CORPORATE_EVENT', () => {
    const event = makeEvent({
      eventType: 'CORPORATE_EVENT',
      rawData: { description: 'quarterly dividend of $0.25 per share', cash_amount: 0.25 },
    });

    const result = classifier.classify(event);
    assert.ok(result);
    assert.strictEqual(result.actionType, 'DIVIDEND');
  });
});
