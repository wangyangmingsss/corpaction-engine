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

export interface CorpActionClientConfig {
  rpcUrl: string;
  registryAddress: string;
  chainId: number;
  dividendDistributorAddress?: string;
  splitExecutorAddress?: string;
}

export interface PendingActionFilter {
  token?: string;
  actionType?: ActionType;
  state?: ActionState;
}
