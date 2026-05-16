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
  totalAmount: bigint;
  amountPerShare: bigint;
  merkleRoot: string;
  snapshotBlock: bigint;
  claimDeadline: bigint;
  withholding: boolean;
  withholdingBps: bigint;
}

export interface SplitParams {
  numerator: bigint;
  denominator: bigint;
  isReverse: boolean;
  expectedNewMultiplier: bigint;
  fractionalHandling: bigint;
  cashInLieuToken: string;
  cashInLieuPrice: bigint;
}

export interface MergerParams {
  mergerType: number;
  acquiringToken: string;
  exchangeRatioNum: bigint;
  exchangeRatioDen: bigint;
  cashPerShare: bigint;
  cashToken: string;
  electionDeadline: bigint;
  hasElection: boolean;
  prorationFactor: bigint;
  merkleRoot: string;
  totalCashPool: bigint;
}

export interface DelistingParams {
  announcementTime: bigint;
  sellOnlyTime: bigint;
  priceLockTime: bigint;
  finalPrice: bigint;
  settlementToken: string;
  merkleRoot: string;
  totalPool: bigint;
  claimDeadline: bigint;
}

export interface SpinoffParams {
  newToken: string;
  distributionRatioNum: bigint;
  distributionRatioDen: bigint;
  merkleRoot: string;
  snapshotBlock: bigint;
  claimDeadline: bigint;
}

export interface TickerChangeParams {
  newToken: string;
  newTicker: string;
  newName: string;
  merkleRoot: string;
  snapshotBlock: bigint;
  claimDeadline: bigint;
}

export interface LiquidationParams {
  announcementTime: bigint;
  sellOnlyTime: bigint;
  priceLockTime: bigint;
  finalPrice: bigint;
  settlementToken: string;
  merkleRoot: string;
  totalPool: bigint;
  claimDeadline: bigint;
}

export type DecodedActionParams =
  | DividendParams
  | SplitParams
  | MergerParams
  | DelistingParams
  | SpinoffParams
  | TickerChangeParams
  | LiquidationParams;

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
