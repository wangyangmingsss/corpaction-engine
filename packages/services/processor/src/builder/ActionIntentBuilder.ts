import { ethers } from 'ethers';

export interface ClassifiedEvent {
  ticker: string;
  isin?: string;
  actionType: string;
  confidence: string;
  params: Record<string, unknown>;
  sourceType: string;
  sourceId: string;
  contentHash: string;
}

export interface ActionIntentData {
  intentId: string;
  actionType: number;
  targetToken: string;
  ticker: string;
  isin: string;
  recordDate: number;
  exDate: number;
  effectiveDate: number;
  actionParams: string;
  sourceAttestation: string;
}

// ActionType enum mapping
const ACTION_TYPE_MAP: Record<string, number> = {
  DIVIDEND: 0,
  FORWARD_SPLIT: 1,
  REVERSE_SPLIT: 2,
  MERGER_CASH: 3,
  MERGER_STOCK: 4,
  MERGER_HYBRID: 5,
  SPINOFF: 6,
  DELISTING: 7,
  LIQUIDATION: 8,
  TICKER_CHANGE: 9,
};

export class ActionIntentBuilder {
  private tokenRegistry: Map<string, string>;

  constructor(tokenRegistry: Map<string, string>) {
    this.tokenRegistry = tokenRegistry;
  }

  build(event: ClassifiedEvent): ActionIntentData | null {
    const targetToken = this.tokenRegistry.get(event.ticker);
    if (!targetToken) return null;

    const actionTypeNum = ACTION_TYPE_MAP[event.actionType];
    if (actionTypeNum === undefined) return null;

    const intentId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['string', 'string', 'bytes32'],
        [event.sourceType, event.sourceId, ethers.id(event.contentHash)]
      )
    );

    const sourceAttestation = ethers.keccak256(
      ethers.toUtf8Bytes(event.contentHash)
    );

    const actionParams = this.encodeActionParams(event.actionType, event.params);
    const dates = this.extractDates(event.params);

    return {
      intentId,
      actionType: actionTypeNum,
      targetToken,
      ticker: event.ticker,
      isin: event.isin || '',
      recordDate: dates.recordDate,
      exDate: dates.exDate,
      effectiveDate: dates.effectiveDate,
      actionParams,
      sourceAttestation,
    };
  }

  private encodeActionParams(actionType: string, params: Record<string, unknown>): string {
    const coder = ethers.AbiCoder.defaultAbiCoder();

    switch (actionType) {
      case 'DIVIDEND':
        return coder.encode(
          ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256', 'bool', 'uint256'],
          [
            params.paymentToken || ethers.ZeroAddress,
            params.totalAmount || 0,
            params.amountPerShare || 0,
            params.merkleRoot || ethers.ZeroHash,
            params.snapshotBlock || 0,
            params.claimDeadline || 0,
            params.withholding || false,
            params.withholdingBps || 0,
          ]
        );

      case 'FORWARD_SPLIT':
      case 'REVERSE_SPLIT':
        return coder.encode(
          ['uint256', 'uint256', 'bool', 'uint256', 'uint256', 'address', 'uint256'],
          [
            params.numerator || 0,
            params.denominator || 0,
            actionType === 'REVERSE_SPLIT',
            params.expectedNewMultiplier || 0,
            params.fractionalHandling || 0,
            params.cashInLieuToken || ethers.ZeroAddress,
            params.cashInLieuPrice || 0,
          ]
        );

      default:
        return coder.encode(['bytes'], [ethers.toUtf8Bytes(JSON.stringify(params))]);
    }
  }

  private extractDates(params: Record<string, unknown>): {
    recordDate: number;
    exDate: number;
    effectiveDate: number;
  } {
    const toTimestamp = (val: unknown): number => {
      if (!val) return Math.floor(Date.now() / 1000);
      if (typeof val === 'number') return val;
      return Math.floor(new Date(String(val)).getTime() / 1000);
    };

    return {
      recordDate: toTimestamp(params.record_date || params.recordDate),
      exDate: toTimestamp(params.ex_date || params.exDate || params.ex_dividend_date),
      effectiveDate: toTimestamp(params.effective_date || params.effectiveDate || params.pay_date),
    };
  }
}
