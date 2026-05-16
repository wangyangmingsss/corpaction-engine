import { describe, it } from 'node:test';
import assert from 'node:assert';
import { MerkleTreeBuilder, HolderEntry } from '../src/builder/MerkleTreeBuilder';
import { ethers } from 'ethers';

describe('MerkleTreeBuilder', () => {
  const builder = new MerkleTreeBuilder();

  it('builds a tree from a holder list and returns valid root', () => {
    const holders: HolderEntry[] = [
      { address: '0x1111111111111111111111111111111111111111', amount: 1000n },
      { address: '0x2222222222222222222222222222222222222222', amount: 2000n },
      { address: '0x3333333333333333333333333333333333333333', amount: 3000n },
    ];

    const tree = builder.buildTree(holders);

    assert.ok(tree.root.startsWith('0x'));
    assert.strictEqual(tree.root.length, 66); // 32 bytes hex
    assert.strictEqual(tree.totalHolders, 3);
    assert.strictEqual(tree.totalAmount, '6000');
    assert.strictEqual(tree.leaves.length, 3);
  });

  it('generates valid proofs for each leaf', () => {
    const holders: HolderEntry[] = [
      { address: '0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', amount: 500n },
      { address: '0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', amount: 700n },
      { address: '0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC', amount: 300n },
    ];

    const tree = builder.buildTree(holders);

    for (const leaf of tree.leaves) {
      assert.ok(leaf.proof.length > 0 || tree.totalHolders === 1);
      assert.ok(leaf.leaf.startsWith('0x'));
      assert.ok(leaf.leaf.length === 66);
      // Each proof element should be a valid 32-byte hash
      for (const p of leaf.proof) {
        assert.ok(p.startsWith('0x'));
        assert.strictEqual(p.length, 66);
      }
    }
  });

  it('root is deterministic for same inputs', () => {
    const holders: HolderEntry[] = [
      { address: '0x1111111111111111111111111111111111111111', amount: 100n },
      { address: '0x2222222222222222222222222222222222222222', amount: 200n },
    ];

    const tree1 = builder.buildTree(holders);
    const tree2 = builder.buildTree(holders);

    assert.strictEqual(tree1.root, tree2.root);
    assert.deepStrictEqual(
      tree1.leaves.map(l => l.leaf),
      tree2.leaves.map(l => l.leaf)
    );
  });

  it('handles single holder edge case', () => {
    const holders: HolderEntry[] = [
      { address: '0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD', amount: 999n },
    ];

    const tree = builder.buildTree(holders);

    assert.strictEqual(tree.totalHolders, 1);
    assert.strictEqual(tree.totalAmount, '999');
    assert.ok(tree.root.startsWith('0x'));
    assert.strictEqual(tree.root.length, 66);
    // Root should equal the single leaf hash
    assert.strictEqual(tree.root, tree.leaves[0].leaf);
    // Proof should be empty for single holder
    assert.strictEqual(tree.leaves[0].proof.length, 0);
  });

  it('different holder sets produce different roots', () => {
    const holdersA: HolderEntry[] = [
      { address: '0x1111111111111111111111111111111111111111', amount: 100n },
    ];
    const holdersB: HolderEntry[] = [
      { address: '0x1111111111111111111111111111111111111111', amount: 200n },
    ];

    const treeA = builder.buildTree(holdersA);
    const treeB = builder.buildTree(holdersB);

    assert.notStrictEqual(treeA.root, treeB.root);
  });
});
