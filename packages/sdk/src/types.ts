export enum ActionType {
  DIVIDEND = 0,
  FORWARD_SPLIT = 1,
  REVERSE_SPLIT = 2,
  MERGER_CASH = 3,
  MERGER_STOCK = 4,
  MERGER_HYBRID = 5,
  SPINOFF = 6,
  DELISTING = 7,
  LIQUIDATION = 8,
  TICKER_CHANGE = 9,
}

export enum ActionState {
  PROPOSED = 0,
  VALIDATED = 1,
  QUEUED = 2,
  EXECUTING = 3,
  EXECUTED = 4,
  FAILED = 5,
  CANCELLED = 6,
  REVERSED = 7,
  PAUSED = 8,
  EXPIRED = 9,
}

export interface ActionIntent {
  intentId: string;
  actionType: ActionType;
  targetToken: string;
  ticker: string;
  isin: string;
  recordDate: bigint;
  exDate: bigint;
  effectiveDate: bigint;
  actionParams: string;
  sourceAttestation: string;
  state: ActionState;
  createdAt: bigint;
  executedAt: bigint;
}

export interface ActionEvent {
  intentId: string;
  type: string;
  ticker: string;
  targetToken: string;
  params: Record<string, unknown>;
  timestamp: number;
}

export interface PendingActionFilter {
  token?: string;
  actionType?: ActionType;
  state?: ActionState;
}

// ========== ACTION PARAM TYPES ==========

export interface DividendParams {
  paymentToken: string;
  amountPerShare: bigint;
  totalAmount: bigint;
  merkleRoot: string;
  snapshotBlock: bigint;
}

export interface SplitParams {
  numerator: bigint;
  denominator: bigint;
  adjustDerivatives: boolean;
}

export interface MergerParams {
  acquirerToken: string;
  cashPerShare: bigint;
  stockRatio: bigint;
  totalConsideration: bigint;
}

export interface DelistingParams {
  reason: string;
  finalPrice: bigint;
  buybackDeadline: bigint;
  custodianAddress: string;
}

export interface SpinoffParams {
  newToken: string;
  distributionRatio: bigint;
  merkleRoot: string;
  snapshotBlock: bigint;
}

export interface TickerChangeParams {
  oldTicker: string;
  newTicker: string;
  newTokenAddress: string;
  migrationDeadline: bigint;
}

export type DecodedActionParams =
  | DividendParams
  | SplitParams
  | MergerParams
  | DelistingParams
  | SpinoffParams
  | TickerChangeParams;

// ========== ERROR TYPES ==========

export enum CorpActionErrorType {
  RPC_ERROR = 'RPC_ERROR',
  CONTRACT_ERROR = 'CONTRACT_ERROR',
  INVALID_PARAMS = 'INVALID_PARAMS',
  NOT_CONFIGURED = 'NOT_CONFIGURED',
  TIMEOUT = 'TIMEOUT',
  UNKNOWN = 'UNKNOWN',
}

export interface CorpActionClientConfig {
  rpcUrl: string;
  registryAddress: string;
  chainId: number;
  dividendDistributorAddress?: string;
  splitExecutorAddress?: string;
  mergerHandlerAddress?: string;
  delistingManagerAddress?: string;
  spinoffExecutorAddress?: string;
  tickerMigratorAddress?: string;
  maxRetries?: number;
  retryBaseDelayMs?: number;
}
