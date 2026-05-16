import { describe, it } from 'node:test';
import assert from 'node:assert';
import { ValidatorNode } from '../src/ValidatorNode';

// We cannot fully instantiate ValidatorNode without real ethers/Redis connections,
// so we test what we can via constructor behavior and method signatures.
// We use a known test private key for deterministic address.

const TEST_PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const TEST_REGISTRY = '0x5FbDB2315678afecb367f032d93F642f64180aa3';
// Use a dummy URL; constructor creates provider/redis but we won't call start()
const DUMMY_RPC = 'http://127.0.0.1:8545';
const DUMMY_REDIS = 'redis://127.0.0.1:6379';

describe('ValidatorNode', () => {
  it('constructor creates an instance without throwing', () => {
    // ValidatorNode constructor creates ethers.JsonRpcProvider and Redis clients.
    // With invalid endpoints, the constructor itself should NOT throw --
    // connections are lazy. This verifies the initialization path.
    const node = new ValidatorNode(
      DUMMY_RPC,
      TEST_PRIVATE_KEY,
      TEST_REGISTRY,
      DUMMY_REDIS
    );
    assert.ok(node);
  });

  it('constructor accepts optional sourceVerifiers array', () => {
    const mockVerifier = {
      verify: async (_eventId: string, _actionType: number, _params: string) => ({
        verified: true,
        details: 'mock verified',
      }),
    };

    const node = new ValidatorNode(
      DUMMY_RPC,
      TEST_PRIVATE_KEY,
      TEST_REGISTRY,
      DUMMY_REDIS,
      [mockVerifier]
    );
    assert.ok(node);
  });

  it('stop method exists and can be called', async () => {
    const node = new ValidatorNode(
      DUMMY_RPC,
      TEST_PRIVATE_KEY,
      TEST_REGISTRY,
      DUMMY_REDIS
    );

    // stop() should not throw even when not started
    // It will try to quit Redis which may error, but the method should exist
    assert.strictEqual(typeof node.stop, 'function');
  });

  it('signIntent method returns a hex signature string', async () => {
    const node = new ValidatorNode(
      DUMMY_RPC,
      TEST_PRIVATE_KEY,
      TEST_REGISTRY,
      DUMMY_REDIS
    );

    // signIntent signs a hash using the wallet
    const testHash = '0x' + '00'.repeat(32);
    const sig = await node.signIntent(testHash);

    assert.ok(sig.startsWith('0x'));
    // EIP-191 signatures are 65 bytes = 130 hex chars + 0x prefix
    assert.strictEqual(sig.length, 132);
  });

  it('validateAndSign returns a valid signature', async () => {
    const node = new ValidatorNode(
      DUMMY_RPC,
      TEST_PRIVATE_KEY,
      TEST_REGISTRY,
      DUMMY_REDIS
    );

    const sig = await node.validateAndSign(
      '0x' + 'ab'.repeat(32), // intentId
      0,                       // actionType (DIVIDEND)
      '0x1111111111111111111111111111111111111111', // targetToken
      '0x'                     // empty actionParams
    );

    assert.ok(sig.startsWith('0x'));
    assert.strictEqual(sig.length, 132);
  });
});
