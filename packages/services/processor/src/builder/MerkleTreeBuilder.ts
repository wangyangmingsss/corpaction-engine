import { ethers } from 'ethers';

export interface HolderEntry {
  address: string;
  amount: bigint;
}

export interface MerkleTreeData {
  root: string;
  leaves: Array<{
    address: string;
    amount: string;
    leaf: string;
    proof: string[];
    index: number;
  }>;
  totalHolders: number;
  totalAmount: string;
}

export class MerkleTreeBuilder {
  buildTree(holders: HolderEntry[]): MerkleTreeData {
    const leaves = holders.map((h, i) => ({
      address: h.address,
      amount: h.amount.toString(),
      leaf: this.computeLeaf(h.address, h.amount),
      index: i,
    }));

    // Sort leaves for deterministic tree
    leaves.sort((a, b) => (a.leaf < b.leaf ? -1 : 1));

    // Build tree layers
    const layers: string[][] = [leaves.map(l => l.leaf)];
    while (layers[layers.length - 1].length > 1) {
      const currentLayer = layers[layers.length - 1];
      const nextLayer: string[] = [];
      for (let i = 0; i < currentLayer.length; i += 2) {
        if (i + 1 < currentLayer.length) {
          nextLayer.push(this.hashPair(currentLayer[i], currentLayer[i + 1]));
        } else {
          nextLayer.push(currentLayer[i]);
        }
      }
      layers.push(nextLayer);
    }

    const root = layers[layers.length - 1][0] || ethers.ZeroHash;

    // Generate proofs
    const leavesWithProofs = leaves.map((leaf) => ({
      ...leaf,
      proof: this.generateProof(leaf.leaf, layers),
    }));

    const totalAmount = holders.reduce((sum, h) => sum + h.amount, 0n);

    return {
      root,
      leaves: leavesWithProofs,
      totalHolders: holders.length,
      totalAmount: totalAmount.toString(),
    };
  }

  private computeLeaf(address: string, amount: bigint): string {
    const innerHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256'],
        [address, amount]
      )
    );
    return ethers.keccak256(ethers.solidityPacked(['bytes32'], [innerHash]));
  }

  private hashPair(a: string, b: string): string {
    const sorted = a < b ? [a, b] : [b, a];
    return ethers.keccak256(
      ethers.solidityPacked(['bytes32', 'bytes32'], sorted)
    );
  }

  private generateProof(leaf: string, layers: string[][]): string[] {
    const proof: string[] = [];
    let index = layers[0].indexOf(leaf);

    for (let i = 0; i < layers.length - 1; i++) {
      const layer = layers[i];
      const pairIndex = index % 2 === 0 ? index + 1 : index - 1;

      if (pairIndex < layer.length) {
        proof.push(layer[pairIndex]);
      }

      index = Math.floor(index / 2);
    }

    return proof;
  }
}
