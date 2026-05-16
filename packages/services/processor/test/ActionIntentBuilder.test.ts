import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert';
import { ActionIntentBuilder, ClassifiedEvent } from '../src/builder/ActionIntentBuilder';
import { ethers } from 'ethers';

function makeEvent(overrides: Partial<ClassifiedEvent> = {}): ClassifiedEvent {
  return {
    ticker: 'AAPL',
    actionType: 'DIVIDEND',
    confidence: 'HIGH',
    params: {},
    sourceType: 'SEC_EDGAR',
    sourceId: 'EDGAR:0001234567-24-000001',
    contentHash: 'abc123def456',
    ...overrides,
  };
}

describe('ActionIntentBuilder', () => {
  let builder: ActionIntentBuilder;
  const registry = new Map<string, string>();

  beforeEach(() => {
    registry.clear();
    registry.set('AAPL', '0x1111111111111111111111111111111111111111');
    registry.set('TSLA', '0x2222222222222222222222222222222222222222');
    builder = new ActionIntentBuilder(registry);
  });

  it('builds a dividend intent with correct fields', () => {
    const event = makeEvent({
      params: {
        amountPerShare: 1.5,
        paymentToken: ethers.ZeroAddress,
        totalAmount: 1000000,
      },
    });

    const intent = builder.build(event);
    assert.ok(intent);
    assert.strictEqual(intent.actionType, 0); // DIVIDEND = 0
    assert.strictEqual(intent.ticker, 'AAPL');
    assert.strictEqual(intent.targetToken, '0x1111111111111111111111111111111111111111');
    assert.ok(intent.intentId.startsWith('0x'));
    assert.ok(intent.intentId.length === 66); // keccak256 hex
    assert.ok(intent.actionParams.length > 0);
    assert.ok(intent.sourceAttestation.startsWith('0x'));
  });

  it('builds a forward split intent with correct multiplier', () => {
    const event = makeEvent({
      actionType: 'FORWARD_SPLIT',
      params: { numerator: 4, denominator: 1 },
    });

    const intent = builder.build(event);
    assert.ok(intent);
    assert.strictEqual(intent.actionType, 1); // FORWARD_SPLIT = 1
    assert.ok(intent.expectedNewMultiplier !== undefined);
    // 4:1 split => multiplier = 1e18 * 4 / 1 = 4e18
    assert.strictEqual(intent.expectedNewMultiplier, BigInt('4000000000000000000'));
  });

  it('builds a reverse split intent with correct multiplier', () => {
    const event = makeEvent({
      actionType: 'REVERSE_SPLIT',
      params: { numerator: 1, denominator: 10 },
    });

    const intent = builder.build(event);
    assert.ok(intent);
    assert.strictEqual(intent.actionType, 2); // REVERSE_SPLIT = 2
    assert.ok(intent.expectedNewMultiplier !== undefined);
    // 1:10 reverse split => multiplier = 1e18 * 1 / 10 = 1e17
    assert.strictEqual(intent.expectedNewMultiplier, BigInt('100000000000000000'));
  });

  it('handles USDC amount conversion with 6 decimals', () => {
    const event = makeEvent({
      params: {
        amountPerShare: 1.5,
        paymentToken: ethers.ZeroAddress,
        totalAmount: 100.25,
      },
    });

    const intent = builder.build(event);
    assert.ok(intent);

    // Decode the actionParams to verify USDC encoding
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const decoded = coder.decode(
      ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256', 'bool', 'uint256'],
      intent.actionParams
    );
    // totalAmount at index 1: 100.25 * 1e6 = 100250000
    assert.strictEqual(decoded[1], BigInt(100250000));
    // amountPerShare at index 2: 1.5 * 1e6 = 1500000
    assert.strictEqual(decoded[2], BigInt(1500000));
  });

  it('computes a deterministic intent ID from source fields', () => {
    const event = makeEvent();
    const intent1 = builder.build(event);
    const intent2 = builder.build(event);
    assert.ok(intent1);
    assert.ok(intent2);
    assert.strictEqual(intent1.intentId, intent2.intentId);
  });

  it('returns null for unknown ticker not in registry', () => {
    const event = makeEvent({ ticker: 'UNKNOWN_TICKER' });
    const intent = builder.build(event);
    assert.strictEqual(intent, null);
  });
});
