import { describe, it, beforeEach, mock } from 'node:test';
import assert from 'node:assert/strict';

import {
  ActionType,
  ActionState,
  CorpActionErrorType,
  CorpActionClientConfig,
  DividendParams,
  SplitParams,
  MergerParams,
  DelistingParams,
  SpinoffParams,
  TickerChangeParams,
  LiquidationParams,
} from '../src/types';

import {
  CorpActionClient,
  CorpActionError,
  RPCError,
  ContractError,
} from '../src/CorpActionClient';

// ========== ActionType enum tests ==========

describe('ActionType', () => {
  it('should have 10 action types', () => {
    const numericValues = Object.values(ActionType).filter(v => typeof v === 'number');
    assert.equal(numericValues.length, 10);
  });

  it('should map DIVIDEND to 0', () => {
    assert.equal(ActionType.DIVIDEND, 0);
  });

  it('should map FORWARD_SPLIT to 1', () => {
    assert.equal(ActionType.FORWARD_SPLIT, 1);
  });

  it('should map REVERSE_SPLIT to 2', () => {
    assert.equal(ActionType.REVERSE_SPLIT, 2);
  });

  it('should map MERGER_CASH to 3', () => {
    assert.equal(ActionType.MERGER_CASH, 3);
  });

  it('should map MERGER_STOCK to 4', () => {
    assert.equal(ActionType.MERGER_STOCK, 4);
  });

  it('should map MERGER_HYBRID to 5', () => {
    assert.equal(ActionType.MERGER_HYBRID, 5);
  });

  it('should map SPINOFF to 6', () => {
    assert.equal(ActionType.SPINOFF, 6);
  });

  it('should map DELISTING to 7', () => {
    assert.equal(ActionType.DELISTING, 7);
  });

  it('should map LIQUIDATION to 8', () => {
    assert.equal(ActionType.LIQUIDATION, 8);
  });

  it('should map TICKER_CHANGE to 9', () => {
    assert.equal(ActionType.TICKER_CHANGE, 9);
  });

  it('should support reverse lookup by numeric value', () => {
    assert.equal(ActionType[0], 'DIVIDEND');
    assert.equal(ActionType[9], 'TICKER_CHANGE');
  });
});

// ========== ActionState enum tests ==========

describe('ActionState', () => {
  it('should have 10 states', () => {
    const numericValues = Object.values(ActionState).filter(v => typeof v === 'number');
    assert.equal(numericValues.length, 10);
  });

  it('should map PROPOSED to 0', () => {
    assert.equal(ActionState.PROPOSED, 0);
  });

  it('should map VALIDATED to 1', () => {
    assert.equal(ActionState.VALIDATED, 1);
  });

  it('should map QUEUED to 2', () => {
    assert.equal(ActionState.QUEUED, 2);
  });

  it('should map EXECUTING to 3', () => {
    assert.equal(ActionState.EXECUTING, 3);
  });

  it('should map EXECUTED to 4', () => {
    assert.equal(ActionState.EXECUTED, 4);
  });

  it('should map FAILED to 5', () => {
    assert.equal(ActionState.FAILED, 5);
  });

  it('should map CANCELLED to 6', () => {
    assert.equal(ActionState.CANCELLED, 6);
  });

  it('should map REVERSED to 7', () => {
    assert.equal(ActionState.REVERSED, 7);
  });

  it('should map PAUSED to 8', () => {
    assert.equal(ActionState.PAUSED, 8);
  });

  it('should map EXPIRED to 9', () => {
    assert.equal(ActionState.EXPIRED, 9);
  });
});

// ========== Client construction tests ==========

describe('CorpActionClient construction', () => {
  const baseConfig: CorpActionClientConfig = {
    rpcUrl: 'http://localhost:8545',
    registryAddress: '0x' + '1'.repeat(40),
    chainId: 1,
  };

  it('should construct with minimal config', () => {
    const client = new CorpActionClient(baseConfig);
    assert.ok(client);
  });

  it('should construct with full config including optional addresses', () => {
    const fullConfig: CorpActionClientConfig = {
      ...baseConfig,
      dividendDistributorAddress: '0x' + '2'.repeat(40),
      splitExecutorAddress: '0x' + '3'.repeat(40),
      mergerHandlerAddress: '0x' + '4'.repeat(40),
      delistingManagerAddress: '0x' + '5'.repeat(40),
      spinoffExecutorAddress: '0x' + '6'.repeat(40),
      tickerMigratorAddress: '0x' + '7'.repeat(40),
      maxRetries: 5,
      retryBaseDelayMs: 500,
    };
    const client = new CorpActionClient(fullConfig);
    assert.ok(client);
  });
});

// ========== decodeActionParams tests ==========

describe('decodeActionParams', () => {
  let client: CorpActionClient;

  beforeEach(() => {
    client = new CorpActionClient({
      rpcUrl: 'http://localhost:8545',
      registryAddress: '0x' + '1'.repeat(40),
      chainId: 1,
    });
  });

  it('should decode DIVIDEND params correctly', () => {
    // Use ethers to ABI-encode known dividend params
    const { ethers } = require('ethers');
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    const paymentToken = '0x' + 'ab'.repeat(20);
    const totalAmount = BigInt('1000000000000000000');
    const amountPerShare = BigInt('100000000000000');
    const merkleRoot = '0x' + 'cc'.repeat(32);
    const snapshotBlock = BigInt(12345678);
    const claimDeadline = BigInt(1700000000);
    const withholding = true;
    const withholdingBps = BigInt(1500);

    const encoded = abiCoder.encode(
      ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256', 'bool', 'uint256'],
      [paymentToken, totalAmount, amountPerShare, merkleRoot, snapshotBlock, claimDeadline, withholding, withholdingBps]
    );

    const result = client.decodeActionParams(ActionType.DIVIDEND, encoded) as DividendParams;

    assert.equal(result.paymentToken.toLowerCase(), paymentToken.toLowerCase());
    assert.equal(result.totalAmount, totalAmount);
    assert.equal(result.amountPerShare, amountPerShare);
    assert.equal(result.merkleRoot, merkleRoot);
    assert.equal(result.snapshotBlock, snapshotBlock);
    assert.equal(result.claimDeadline, claimDeadline);
    assert.equal(result.withholding, withholding);
    assert.equal(result.withholdingBps, withholdingBps);
  });

  it('should decode FORWARD_SPLIT params correctly', () => {
    const { ethers } = require('ethers');
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    const numerator = BigInt(2);
    const denominator = BigInt(1);
    const isReverse = false;
    const expectedNewMultiplier = BigInt(2);
    const fractionalHandling = BigInt(0);
    const cashInLieuToken = '0x' + '00'.repeat(20);
    const cashInLieuPrice = BigInt(0);

    const encoded = abiCoder.encode(
      ['uint256', 'uint256', 'bool', 'uint256', 'uint256', 'address', 'uint256'],
      [numerator, denominator, isReverse, expectedNewMultiplier, fractionalHandling, cashInLieuToken, cashInLieuPrice]
    );

    const result = client.decodeActionParams(ActionType.FORWARD_SPLIT, encoded) as SplitParams;

    assert.equal(result.numerator, numerator);
    assert.equal(result.denominator, denominator);
    assert.equal(result.isReverse, false);
    assert.equal(result.expectedNewMultiplier, expectedNewMultiplier);
    assert.equal(result.fractionalHandling, fractionalHandling);
    assert.equal(result.cashInLieuPrice, cashInLieuPrice);
  });

  it('should decode REVERSE_SPLIT params using the same structure as FORWARD_SPLIT', () => {
    const { ethers } = require('ethers');
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    const encoded = abiCoder.encode(
      ['uint256', 'uint256', 'bool', 'uint256', 'uint256', 'address', 'uint256'],
      [BigInt(1), BigInt(10), true, BigInt(0), BigInt(1), '0x' + '00'.repeat(20), BigInt(50)]
    );

    const result = client.decodeActionParams(ActionType.REVERSE_SPLIT, encoded) as SplitParams;

    assert.equal(result.numerator, BigInt(1));
    assert.equal(result.denominator, BigInt(10));
    assert.equal(result.isReverse, true);
    assert.equal(result.fractionalHandling, BigInt(1));
    assert.equal(result.cashInLieuPrice, BigInt(50));
  });

  it('should throw CorpActionError for unknown action type', () => {
    assert.throws(
      () => client.decodeActionParams(99 as ActionType, '0x'),
      (err: unknown) => {
        assert.ok(err instanceof CorpActionError);
        assert.equal(err.errorType, CorpActionErrorType.INVALID_PARAMS);
        return true;
      }
    );
  });
});

// ========== Error types tests ==========

describe('Error types', () => {
  it('CorpActionError should have correct properties', () => {
    const err = new CorpActionError(CorpActionErrorType.CONTRACT_ERROR, 'test error', { key: 'val' });
    assert.equal(err.name, 'CorpActionError');
    assert.equal(err.errorType, CorpActionErrorType.CONTRACT_ERROR);
    assert.equal(err.message, 'test error');
    assert.deepEqual(err.details, { key: 'val' });
    assert.ok(err instanceof Error);
  });

  it('RPCError should extend CorpActionError with RPC_ERROR type', () => {
    const err = new RPCError('rpc failed', { attempts: 3 });
    assert.equal(err.name, 'RPCError');
    assert.equal(err.errorType, CorpActionErrorType.RPC_ERROR);
    assert.ok(err instanceof CorpActionError);
    assert.ok(err instanceof Error);
  });

  it('ContractError should extend CorpActionError with CONTRACT_ERROR type', () => {
    const err = new ContractError('contract reverted');
    assert.equal(err.name, 'ContractError');
    assert.equal(err.errorType, CorpActionErrorType.CONTRACT_ERROR);
    assert.ok(err instanceof CorpActionError);
    assert.ok(err instanceof Error);
  });

  it('CorpActionErrorType enum should have all expected values', () => {
    assert.equal(CorpActionErrorType.RPC_ERROR, 'RPC_ERROR');
    assert.equal(CorpActionErrorType.CONTRACT_ERROR, 'CONTRACT_ERROR');
    assert.equal(CorpActionErrorType.INVALID_PARAMS, 'INVALID_PARAMS');
    assert.equal(CorpActionErrorType.NOT_CONFIGURED, 'NOT_CONFIGURED');
    assert.equal(CorpActionErrorType.TIMEOUT, 'TIMEOUT');
    assert.equal(CorpActionErrorType.UNKNOWN, 'UNKNOWN');
  });

  it('CorpActionError without details should have undefined details', () => {
    const err = new CorpActionError(CorpActionErrorType.UNKNOWN, 'no details');
    assert.equal(err.details, undefined);
  });
});
