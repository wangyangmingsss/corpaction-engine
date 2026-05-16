import { ethers } from 'ethers';
import {
  ActionType,
  ActionState,
  ActionIntent,
  ActionEvent,
  CorpActionClientConfig,
  PendingActionFilter,
  CorpActionErrorType,
  DecodedActionParams,
  DividendParams,
  SplitParams,
  MergerParams,
  DelistingParams,
  SpinoffParams,
  TickerChangeParams,
  LiquidationParams,
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
  'event EmergencyPaused(address indexed caller, string reason)',
  'event EmergencyResumed(address indexed caller, string reason)',
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

const SPLIT_EXECUTOR_ABI = [
  'function getAdjustmentFactor(bytes32 intentId) external view returns (uint256 numerator, uint256 denominator)',
  'event SplitExecuted(bytes32 indexed intentId, address indexed token, uint256 numerator, uint256 denominator)',
];

const MERGER_HANDLER_ABI = [
  'event MergerExecuted(bytes32 indexed intentId, address indexed targetToken, address indexed acquirerToken)',
];

const DELISTING_MANAGER_ABI = [
  'event DelistingInitiated(bytes32 indexed intentId, address indexed token, uint256 finalPrice)',
];

const SPINOFF_EXECUTOR_ABI = [
  'event SpinoffDistributed(bytes32 indexed intentId, address indexed parentToken, address indexed newToken)',
];

const TICKER_MIGRATOR_ABI = [
  'event TickerMigrated(bytes32 indexed intentId, string oldTicker, string newTicker)',
];

// ========== CUSTOM ERROR TYPES ==========

export class CorpActionError extends Error {
  public readonly errorType: CorpActionErrorType;
  public readonly details?: Record<string, unknown>;

  constructor(errorType: CorpActionErrorType, message: string, details?: Record<string, unknown>) {
    super(message);
    this.name = 'CorpActionError';
    this.errorType = errorType;
    this.details = details;
  }
}

export class RPCError extends CorpActionError {
  constructor(message: string, details?: Record<string, unknown>) {
    super(CorpActionErrorType.RPC_ERROR, message, details);
    this.name = 'RPCError';
  }
}

export class ContractError extends CorpActionError {
  constructor(message: string, details?: Record<string, unknown>) {
    super(CorpActionErrorType.CONTRACT_ERROR, message, details);
    this.name = 'ContractError';
  }
}

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

  onActionValidated(
    callback: (event: { intentId: string; validator: string; count: number; required: number }) => void
  ): () => void {
    const handler = (intentId: string, validator: string, count: bigint, required: bigint) => {
      callback({ intentId, validator, count: Number(count), required: Number(required) });
    };
    this.registry.on('ActionValidated', handler);
    return () => this.registry.off('ActionValidated', handler);
  }

  onActionQueued(
    callback: (event: { intentId: string; executionTime: number }) => void
  ): () => void {
    const handler = (intentId: string, executionTime: bigint) => {
      callback({ intentId, executionTime: Number(executionTime) });
    };
    this.registry.on('ActionQueued', handler);
    return () => this.registry.off('ActionQueued', handler);
  }

  onActionCancelled(
    callback: (event: { intentId: string; reason: string }) => void
  ): () => void {
    const handler = (intentId: string, reason: string) => {
      callback({ intentId, reason });
    };
    this.registry.on('ActionCancelled', handler);
    return () => this.registry.off('ActionCancelled', handler);
  }

  onActionFailed(
    callback: (event: { intentId: string; reason: string }) => void
  ): () => void {
    const handler = (intentId: string, reason: string) => {
      callback({ intentId, reason });
    };
    this.registry.on('ActionFailed', handler);
    return () => this.registry.off('ActionFailed', handler);
  }

  onEmergencyPaused(
    callback: (event: { caller: string; reason: string }) => void
  ): () => void {
    const handler = (caller: string, reason: string) => {
      callback({ caller, reason });
    };
    this.registry.on('EmergencyPaused', handler);
    return () => this.registry.off('EmergencyPaused', handler);
  }

  onEmergencyResumed(
    callback: (event: { caller: string; reason: string }) => void
  ): () => void {
    const handler = (caller: string, reason: string) => {
      callback({ caller, reason });
    };
    this.registry.on('EmergencyResumed', handler);
    return () => this.registry.off('EmergencyResumed', handler);
  }

  onDividendClaimed(
    callback: (event: { intentId: string; claimer: string; amount: bigint }) => void
  ): () => void {
    if (!this.config.dividendDistributorAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'DividendDistributor address not configured');
    }
    const distributor = new ethers.Contract(
      this.config.dividendDistributorAddress,
      DIVIDEND_ABI,
      this.provider
    );
    const handler = (intentId: string, claimer: string, amount: bigint) => {
      callback({ intentId, claimer, amount });
    };
    distributor.on('DividendClaimed', handler);
    return () => distributor.off('DividendClaimed', handler);
  }

  onSplitExecuted(
    callback: (event: { intentId: string; token: string; numerator: bigint; denominator: bigint }) => void
  ): () => void {
    if (!this.config.splitExecutorAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'SplitExecutor address not configured');
    }
    const executor = new ethers.Contract(
      this.config.splitExecutorAddress,
      SPLIT_EXECUTOR_ABI,
      this.provider
    );
    const handler = (intentId: string, token: string, numerator: bigint, denominator: bigint) => {
      callback({ intentId, token, numerator, denominator });
    };
    executor.on('SplitExecuted', handler);
    return () => executor.off('SplitExecuted', handler);
  }

  onMergerExecuted(
    callback: (event: { intentId: string; targetToken: string; acquirerToken: string }) => void
  ): () => void {
    if (!this.config.mergerHandlerAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'MergerHandler address not configured');
    }
    const handler_contract = new ethers.Contract(
      this.config.mergerHandlerAddress,
      MERGER_HANDLER_ABI,
      this.provider
    );
    const handler = (intentId: string, targetToken: string, acquirerToken: string) => {
      callback({ intentId, targetToken, acquirerToken });
    };
    handler_contract.on('MergerExecuted', handler);
    return () => handler_contract.off('MergerExecuted', handler);
  }

  onDelistingInitiated(
    callback: (event: { intentId: string; token: string; finalPrice: bigint }) => void
  ): () => void {
    if (!this.config.delistingManagerAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'DelistingManager address not configured');
    }
    const manager = new ethers.Contract(
      this.config.delistingManagerAddress,
      DELISTING_MANAGER_ABI,
      this.provider
    );
    const handler = (intentId: string, token: string, finalPrice: bigint) => {
      callback({ intentId, token, finalPrice });
    };
    manager.on('DelistingInitiated', handler);
    return () => manager.off('DelistingInitiated', handler);
  }

  onSpinoffDistributed(
    callback: (event: { intentId: string; parentToken: string; newToken: string }) => void
  ): () => void {
    if (!this.config.spinoffExecutorAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'SpinoffExecutor address not configured');
    }
    const executor = new ethers.Contract(
      this.config.spinoffExecutorAddress,
      SPINOFF_EXECUTOR_ABI,
      this.provider
    );
    const handler = (intentId: string, parentToken: string, newToken: string) => {
      callback({ intentId, parentToken, newToken });
    };
    executor.on('SpinoffDistributed', handler);
    return () => executor.off('SpinoffDistributed', handler);
  }

  onTickerMigrated(
    callback: (event: { intentId: string; oldTicker: string; newTicker: string }) => void
  ): () => void {
    if (!this.config.tickerMigratorAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'TickerMigrator address not configured');
    }
    const migrator = new ethers.Contract(
      this.config.tickerMigratorAddress,
      TICKER_MIGRATOR_ABI,
      this.provider
    );
    const handler = (intentId: string, oldTicker: string, newTicker: string) => {
      callback({ intentId, oldTicker, newTicker });
    };
    migrator.on('TickerMigrated', handler);
    return () => migrator.off('TickerMigrated', handler);
  }

  // ========== PARAMETER DECODING ==========

  decodeActionParams(actionType: ActionType, rawParams: string): DecodedActionParams {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    switch (actionType) {
      case ActionType.DIVIDEND: {
        const decoded = abiCoder.decode(
          ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256', 'bool', 'uint256'],
          rawParams
        );
        return {
          paymentToken: decoded[0],
          totalAmount: BigInt(decoded[1]),
          amountPerShare: BigInt(decoded[2]),
          merkleRoot: decoded[3],
          snapshotBlock: BigInt(decoded[4]),
          claimDeadline: BigInt(decoded[5]),
          withholding: decoded[6],
          withholdingBps: BigInt(decoded[7]),
        } as DividendParams;
      }
      case ActionType.FORWARD_SPLIT:
      case ActionType.REVERSE_SPLIT: {
        const decoded = abiCoder.decode(
          ['uint256', 'uint256', 'bool', 'uint256', 'uint256', 'address', 'uint256'],
          rawParams
        );
        return {
          numerator: BigInt(decoded[0]),
          denominator: BigInt(decoded[1]),
          isReverse: decoded[2],
          expectedNewMultiplier: BigInt(decoded[3]),
          fractionalHandling: BigInt(decoded[4]),
          cashInLieuToken: decoded[5],
          cashInLieuPrice: BigInt(decoded[6]),
        } as SplitParams;
      }
      case ActionType.MERGER_CASH:
      case ActionType.MERGER_STOCK:
      case ActionType.MERGER_HYBRID: {
        const decoded = abiCoder.decode(
          ['uint8', 'address', 'uint256', 'uint256', 'uint256', 'address', 'uint256', 'bool', 'uint256', 'bytes32', 'uint256'],
          rawParams
        );
        return {
          mergerType: Number(decoded[0]),
          acquiringToken: decoded[1],
          exchangeRatioNum: BigInt(decoded[2]),
          exchangeRatioDen: BigInt(decoded[3]),
          cashPerShare: BigInt(decoded[4]),
          cashToken: decoded[5],
          electionDeadline: BigInt(decoded[6]),
          hasElection: decoded[7],
          prorationFactor: BigInt(decoded[8]),
          merkleRoot: decoded[9],
          totalCashPool: BigInt(decoded[10]),
        } as MergerParams;
      }
      case ActionType.DELISTING: {
        const decoded = abiCoder.decode(
          ['uint256', 'uint256', 'uint256', 'uint256', 'address', 'bytes32', 'uint256', 'uint256'],
          rawParams
        );
        return {
          announcementTime: BigInt(decoded[0]),
          sellOnlyTime: BigInt(decoded[1]),
          priceLockTime: BigInt(decoded[2]),
          finalPrice: BigInt(decoded[3]),
          settlementToken: decoded[4],
          merkleRoot: decoded[5],
          totalPool: BigInt(decoded[6]),
          claimDeadline: BigInt(decoded[7]),
        } as DelistingParams;
      }
      case ActionType.SPINOFF: {
        const decoded = abiCoder.decode(
          ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256'],
          rawParams
        );
        return {
          newToken: decoded[0],
          distributionRatioNum: BigInt(decoded[1]),
          distributionRatioDen: BigInt(decoded[2]),
          merkleRoot: decoded[3],
          snapshotBlock: BigInt(decoded[4]),
          claimDeadline: BigInt(decoded[5]),
        } as SpinoffParams;
      }
      case ActionType.TICKER_CHANGE: {
        const decoded = abiCoder.decode(
          ['address', 'string', 'string', 'bytes32', 'uint256', 'uint256'],
          rawParams
        );
        return {
          newToken: decoded[0],
          newTicker: decoded[1],
          newName: decoded[2],
          merkleRoot: decoded[3],
          snapshotBlock: BigInt(decoded[4]),
          claimDeadline: BigInt(decoded[5]),
        } as TickerChangeParams;
      }
      case ActionType.LIQUIDATION: {
        const decoded = abiCoder.decode(
          ['uint256', 'uint256', 'uint256', 'uint256', 'address', 'bytes32', 'uint256', 'uint256'],
          rawParams
        );
        return {
          announcementTime: BigInt(decoded[0]),
          sellOnlyTime: BigInt(decoded[1]),
          priceLockTime: BigInt(decoded[2]),
          finalPrice: BigInt(decoded[3]),
          settlementToken: decoded[4],
          merkleRoot: decoded[5],
          totalPool: BigInt(decoded[6]),
          claimDeadline: BigInt(decoded[7]),
        } as LiquidationParams;
      }
      default:
        throw new CorpActionError(
          CorpActionErrorType.INVALID_PARAMS,
          `Unknown action type: ${actionType}`
        );
    }
  }

  // ========== INTEGRATION HELPERS ==========

  /**
   * Batch-claim dividends for the signer's own address across multiple intentIds.
   *
   * NOTE: The on-chain DividendDistributor contract validates msg.sender for claims,
   * so claiming on behalf of another address is not supported. This method allows
   * the signer to claim their own dividends for multiple intents in sequence.
   */
  async batchClaimDividends(
    claims: Array<{ intentId: string; amount: bigint; merkleProof: string[] }>,
    signer: ethers.Signer
  ): Promise<ethers.TransactionReceipt[]> {
    if (!this.config.dividendDistributorAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'DividendDistributor address not configured');
    }

    const distributor = new ethers.Contract(
      this.config.dividendDistributorAddress,
      DIVIDEND_ABI,
      signer
    );

    const receipts: ethers.TransactionReceipt[] = [];
    for (const claim of claims) {
      const receipt = await this._callWithRetry(async () => {
        const tx = await distributor.claimDividend(claim.intentId, claim.amount, claim.merkleProof);
        return await tx.wait();
      });
      receipts.push(receipt);
    }

    return receipts;
  }

  /**
   * Compute the strike price adjustment factor for a split by reading the
   * SplitExecuted event data from the chain and calculating newMultiplier / oldMultiplier.
   *
   * This is computed client-side since the contract does not expose a
   * getAdjustmentFactor function.
   */
  async getStrikePriceAdjustment(
    intentId: string
  ): Promise<{ numerator: bigint; denominator: bigint; adjustmentFactor: number }> {
    if (!this.config.splitExecutorAddress) {
      throw new CorpActionError(CorpActionErrorType.NOT_CONFIGURED, 'SplitExecutor address not configured');
    }

    const executor = new ethers.Contract(
      this.config.splitExecutorAddress,
      SPLIT_EXECUTOR_ABI,
      this.provider
    );

    return this._callWithRetry(async () => {
      // Query the SplitExecuted event for this intentId to get numerator/denominator
      const filter = executor.filters.SplitExecuted(intentId);
      const events = await executor.queryFilter(filter);

      if (events.length === 0) {
        throw new CorpActionError(
          CorpActionErrorType.CONTRACT_ERROR,
          `No SplitExecuted event found for intentId ${intentId}`
        );
      }

      const event = events[events.length - 1];
      const args = (event as ethers.EventLog).args;
      const numerator = BigInt(args[2]);
      const denominator = BigInt(args[3]);

      // adjustmentFactor = newMultiplier / oldMultiplier = numerator / denominator
      const adjustmentFactor = Number(numerator) / Number(denominator);

      return { numerator, denominator, adjustmentFactor };
    });
  }

  // ========== INTERNAL ==========

  private async _callWithRetry<T>(fn: () => Promise<T>): Promise<T> {
    const maxRetries = this.config.maxRetries ?? 3;
    const baseDelay = this.config.retryBaseDelayMs ?? 1000;

    let lastError: unknown;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        return await fn();
      } catch (error: unknown) {
        lastError = error;
        if (attempt < maxRetries) {
          const delay = baseDelay * Math.pow(2, attempt);
          await new Promise((resolve) => setTimeout(resolve, delay));
        }
      }
    }

    const message = lastError instanceof Error ? lastError.message : String(lastError);
    throw new RPCError(`RPC call failed after ${maxRetries + 1} attempts: ${message}`, {
      attempts: maxRetries + 1,
    });
  }

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
