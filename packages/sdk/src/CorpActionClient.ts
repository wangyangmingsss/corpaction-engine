import { ethers } from 'ethers';
import {
  ActionType,
  ActionState,
  ActionIntent,
  ActionEvent,
  CorpActionClientConfig,
  PendingActionFilter,
} from './types';

const REGISTRY_ABI = [
  'function getAction(bytes32 intentId) external view returns (tuple(bytes32 intentId, uint8 actionType, address targetToken, string ticker, string isin, uint256 recordDate, uint256 exDate, uint256 effectiveDate, bytes actionParams, bytes32 sourceAttestation, uint8 state, uint256 createdAt, uint256 executedAt))',
  'function getActionsByToken(address token) external view returns (bytes32[])',
  'function getValidationCount(bytes32 intentId) external view returns (uint256)',
  'function getExecutionTime(bytes32 intentId) external view returns (uint256)',
  'event ActionProposed(bytes32 indexed intentId, uint8 indexed actionType, address indexed targetToken, string ticker)',
  'event ActionValidated(bytes32 indexed intentId, address validator, uint256 count, uint256 required)',
  'event ActionQueued(bytes32 indexed intentId, uint256 executionTime)',
  'event ActionExecuted(bytes32 indexed intentId, uint8 indexed actionType, address indexed targetToken, bytes result)',
  'event ActionCancelled(bytes32 indexed intentId, string reason)',
  'event ActionFailed(bytes32 indexed intentId, string reason)',
];

const DIVIDEND_ABI = [
  'function claimDividend(bytes32 intentId, uint256 amount, bytes32[] calldata merkleProof) external',
  'function claimed(bytes32 intentId, address claimer) external view returns (bool)',
  'event DividendClaimed(bytes32 indexed intentId, address indexed claimer, uint256 amount)',
];

const ATTESTATION_ABI = [
  'function getAttestation(bytes32 attestationId) external view returns (tuple(bytes32 intentId, string sourceType, string sourceId, string sourceUrl, bytes32 contentHash, uint256 ingestedAt, uint256 blockNumber, address attester, bytes signature, bool verified))',
  'function getAttestationsForIntent(bytes32 intentId) external view returns (bytes32[])',
];

export class CorpActionClient {
  private provider: ethers.JsonRpcProvider;
  private registry: ethers.Contract;
  private config: CorpActionClientConfig;

  constructor(config: CorpActionClientConfig) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.registry = new ethers.Contract(config.registryAddress, REGISTRY_ABI, this.provider);
  }

  // ========== QUERIES ==========

  async getAction(intentId: string): Promise<ActionIntent> {
    const result = await this.registry.getAction(intentId);
    return this.parseActionIntent(result);
  }

  async getActionsByToken(tokenAddress: string): Promise<string[]> {
    return await this.registry.getActionsByToken(tokenAddress);
  }

  async getPendingActions(filter?: PendingActionFilter): Promise<ActionIntent[]> {
    if (!filter?.token) return [];

    const intentIds = await this.registry.getActionsByToken(filter.token);
    const actions: ActionIntent[] = [];

    for (const id of intentIds) {
      const action = await this.getAction(id);
      if (filter.actionType !== undefined && action.actionType !== filter.actionType) continue;
      if (filter.state !== undefined && action.state !== filter.state) continue;
      if (action.state <= ActionState.QUEUED) {
        actions.push(action);
      }
    }

    return actions;
  }

  async getValidationCount(intentId: string): Promise<number> {
    return Number(await this.registry.getValidationCount(intentId));
  }

  async getExecutionTime(intentId: string): Promise<number> {
    return Number(await this.registry.getExecutionTime(intentId));
  }

  // ========== DIVIDEND CLAIMS ==========

  async claimDividend(
    intentId: string,
    amount: bigint,
    merkleProof: string[],
    signer: ethers.Signer
  ): Promise<ethers.TransactionReceipt> {
    if (!this.config.dividendDistributorAddress) {
      throw new Error('DividendDistributor address not configured');
    }

    const distributor = new ethers.Contract(
      this.config.dividendDistributorAddress,
      DIVIDEND_ABI,
      signer
    );

    const tx = await distributor.claimDividend(intentId, amount, merkleProof);
    return await tx.wait();
  }

  async hasClaimed(intentId: string, address: string): Promise<boolean> {
    if (!this.config.dividendDistributorAddress) return false;

    const distributor = new ethers.Contract(
      this.config.dividendDistributorAddress,
      DIVIDEND_ABI,
      this.provider
    );

    return await distributor.claimed(intentId, address);
  }

  // ========== ATTESTATION VERIFICATION ==========

  async verifyAttestation(
    intentId: string,
    attestationRegistryAddress: string
  ): Promise<boolean> {
    const attestationRegistry = new ethers.Contract(
      attestationRegistryAddress,
      ATTESTATION_ABI,
      this.provider
    );

    const attestationIds = await attestationRegistry.getAttestationsForIntent(intentId);
    if (attestationIds.length === 0) return false;

    for (const id of attestationIds) {
      const att = await attestationRegistry.getAttestation(id);
      if (att.verified) return true;
    }

    return false;
  }

  // ========== EVENT SUBSCRIPTIONS ==========

  onAction(
    tokenAddress: string,
    callback: (event: ActionEvent) => void
  ): () => void {
    const filter = this.registry.filters.ActionExecuted(null, null, tokenAddress);

    const handler = (intentId: string, actionType: number, targetToken: string, result: string) => {
      callback({
        intentId,
        type: ActionType[actionType] || 'UNKNOWN',
        ticker: '',
        targetToken,
        params: { result },
        timestamp: Math.floor(Date.now() / 1000),
      });
    };

    this.registry.on(filter, handler);

    return () => {
      this.registry.off(filter, handler);
    };
  }

  onActionProposed(
    callback: (event: { intentId: string; actionType: number; targetToken: string; ticker: string }) => void
  ): () => void {
    const handler = (intentId: string, actionType: number, targetToken: string, ticker: string) => {
      callback({ intentId, actionType, targetToken, ticker });
    };

    this.registry.on('ActionProposed', handler);
    return () => this.registry.off('ActionProposed', handler);
  }

  // ========== INTERNAL ==========

  private parseActionIntent(result: ethers.Result): ActionIntent {
    return {
      intentId: result[0],
      actionType: Number(result[1]) as ActionType,
      targetToken: result[2],
      ticker: result[3],
      isin: result[4],
      recordDate: BigInt(result[5]),
      exDate: BigInt(result[6]),
      effectiveDate: BigInt(result[7]),
      actionParams: result[8],
      sourceAttestation: result[9],
      state: Number(result[10]) as ActionState,
      createdAt: BigInt(result[11]),
      executedAt: BigInt(result[12]),
    };
  }
}
