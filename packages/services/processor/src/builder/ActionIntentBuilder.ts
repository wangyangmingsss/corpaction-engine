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
  expectedNewMultiplier?: bigint;
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

// Maximum safe value for uint256 components to prevent overflow
const MAX_UINT128 = (1n << 128n) - 1n;
const MULTIPLIER_DECIMALS = 18;
const MULTIPLIER_BASE = 10n ** BigInt(MULTIPLIER_DECIMALS);
const USDC_DECIMALS = 6;
const USDC_BASE = 10n ** BigInt(USDC_DECIMALS);

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

    const result: ActionIntentData = {
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

    // Pre-calculate ERC-8056 multiplier for split events
    if (event.actionType === 'FORWARD_SPLIT' || event.actionType === 'REVERSE_SPLIT') {
      result.expectedNewMultiplier = this.calculateExpectedMultiplier(event.params);
    }

    return result;
  }

  /**
   * Pre-calculate the expected new ERC-8056 multiplier after a split.
   *
   * For a forward split N:D, the new multiplier = currentMultiplier * N / D
   * For a reverse split N:D (N < D), the new multiplier = currentMultiplier * N / D
   *
   * Uses fixed-point arithmetic with 18 decimals to avoid floating point issues.
   * Includes overflow protection: if any intermediate value exceeds MAX_UINT128,
   * the calculation is scaled down to prevent uint256 overflow on-chain.
   */
  private calculateExpectedMultiplier(params: Record<string, unknown>): bigint {
    const numerator = BigInt(Number(params.numerator) || 1);
    const denominator = BigInt(Number(params.denominator) || 1);

    if (denominator === 0n) {
      throw new Error('Split denominator cannot be zero');
    }

    // Current multiplier defaults to 1.0 (1e18 in fixed-point)
    const currentMultiplier = params.currentMultiplier
      ? BigInt(String(params.currentMultiplier))
      : MULTIPLIER_BASE;

    // Overflow protection: check if multiplication would overflow
    // We compute: newMultiplier = currentMultiplier * numerator / denominator
    const safeNumerator = this.clampBigInt(numerator, MAX_UINT128);
    const safeDenominator = this.clampBigInt(denominator, MAX_UINT128);
    const safeCurrentMultiplier = this.clampBigInt(currentMultiplier, MAX_UINT128);

    // Use intermediate scaling to prevent overflow:
    // result = (currentMultiplier * numerator) / denominator
    // If currentMultiplier * numerator > MAX_UINT256, scale down first
    const intermediate = safeCurrentMultiplier * safeNumerator;
    const newMultiplier = intermediate / safeDenominator;

    if (newMultiplier === 0n) {
      throw new Error('Resulting multiplier would be zero; split ratio too extreme');
    }

    return newMultiplier;
  }

  /**
   * Clamp a BigInt to a maximum value for overflow protection.
   */
  private clampBigInt(value: bigint, max: bigint): bigint {
    if (value > max) return max;
    if (value < 1n) return 1n;
    return value;
  }

  /**
   * Convert a dollar amount to USDC-denominated amount (6 decimals).
   * E.g., $1.50 => 1500000n
   */
  private toUsdcAmount(dollars: unknown): bigint {
    if (dollars == null) return 0n;
    const num = Number(dollars);
    if (isNaN(num)) return 0n;
    // Multiply by 10^6 using integer math to avoid floating point issues
    return BigInt(Math.round(num * 1e6));
  }

  private encodeActionParams(actionType: string, params: Record<string, unknown>): string {
    const coder = ethers.AbiCoder.defaultAbiCoder();

    switch (actionType) {
      case 'DIVIDEND':
        return coder.encode(
          ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256', 'bool', 'uint256'],
          [
            params.paymentToken || ethers.ZeroAddress,
            this.toUsdcAmount(params.totalAmount),
            this.toUsdcAmount(params.amountPerShare),
            params.merkleRoot || ethers.ZeroHash,
            params.snapshotBlock || 0,
            params.claimDeadline || 0,
            params.withholding || false,
            params.withholdingBps || 0,
          ]
        );

      case 'FORWARD_SPLIT':
      case 'REVERSE_SPLIT': {
        const numerator = BigInt(Number(params.numerator) || 0);
        const denominator = BigInt(Number(params.denominator) || 0);

        // Overflow protection for ratio values
        const safeNum = this.clampBigInt(numerator, MAX_UINT128);
        const safeDenom = this.clampBigInt(denominator, MAX_UINT128);

        const expectedMul = (params.expectedNewMultiplier != null)
          ? BigInt(String(params.expectedNewMultiplier))
          : this.calculateExpectedMultiplier(params);

        return coder.encode(
          ['uint256', 'uint256', 'bool', 'uint256', 'uint256', 'address', 'uint256'],
          [
            safeNum,
            safeDenom,
            actionType === 'REVERSE_SPLIT',
            expectedMul,
            params.fractionalHandling || 0,
            params.cashInLieuToken || ethers.ZeroAddress,
            this.toUsdcAmount(params.cashInLieuPrice),
          ]
        );
      }

      case 'MERGER_CASH':
      case 'MERGER_STOCK':
      case 'MERGER_HYBRID': {
        // Matches MergerHandler.MergerParams struct:
        // (uint8 mergerType, address acquiringToken, uint256 exchangeRatioNum, uint256 exchangeRatioDen,
        //  uint256 cashPerShare, address cashToken, uint256 electionDeadline,
        //  bool hasElection, uint256 prorationFactor, bytes32 merkleRoot, uint256 totalCashPool)
        const mergerTypeMap: Record<string, number> = {
          MERGER_CASH: 0,
          MERGER_STOCK: 1,
          MERGER_HYBRID: 2,
        };
        return coder.encode(
          ['uint8', 'address', 'uint256', 'uint256', 'uint256', 'address', 'uint256', 'bool', 'uint256', 'bytes32', 'uint256'],
          [
            mergerTypeMap[actionType] ?? 0,
            params.acquiringToken || ethers.ZeroAddress,
            params.exchangeRatioNum || params.exchange_ratio_num || 0,
            params.exchangeRatioDen || params.exchange_ratio_den || 1,
            this.toUsdcAmount(params.cashPerShare || params.cash_per_share),
            params.cashToken || ethers.ZeroAddress,
            params.electionDeadline || params.election_deadline || 0,
            params.hasElection || params.has_election || false,
            params.prorationFactor || params.proration_factor || 10000, // BPS, default 100%
            params.merkleRoot || ethers.ZeroHash,
            this.toUsdcAmount(params.totalCashPool || params.total_cash_pool),
          ]
        );
      }

      case 'SPINOFF': {
        // Matches SpinoffExecutor.SpinoffParams struct:
        // (address newToken, uint256 distributionRatioNum, uint256 distributionRatioDen,
        //  bytes32 merkleRoot, uint256 snapshotBlock, uint256 claimDeadline)
        return coder.encode(
          ['address', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256'],
          [
            params.newToken || params.new_token || ethers.ZeroAddress,
            params.distributionRatioNum || params.distribution_ratio_num || 1,
            params.distributionRatioDen || params.distribution_ratio_den || 1,
            params.merkleRoot || ethers.ZeroHash,
            params.snapshotBlock || params.snapshot_block || 0,
            params.claimDeadline || params.claim_deadline || 0,
          ]
        );
      }

      case 'DELISTING':
      case 'LIQUIDATION': {
        // Matches DelistingManager.DelistingParams struct:
        // (uint256 announcementTime, uint256 sellOnlyTime, uint256 priceLockTime,
        //  uint256 finalPrice, address settlementToken, bytes32 merkleRoot,
        //  uint256 totalPool, uint256 claimDeadline)
        return coder.encode(
          ['uint256', 'uint256', 'uint256', 'uint256', 'address', 'bytes32', 'uint256', 'uint256'],
          [
            params.announcementTime || params.announcement_time || 0,
            params.sellOnlyTime || params.sell_only_time || 0,
            params.priceLockTime || params.price_lock_time || 0,
            this.toUsdcAmount(params.finalPrice || params.final_price),
            params.settlementToken || params.settlement_token || ethers.ZeroAddress,
            params.merkleRoot || ethers.ZeroHash,
            this.toUsdcAmount(params.totalPool || params.total_pool),
            params.claimDeadline || params.claim_deadline || 0,
          ]
        );
      }

      case 'TICKER_CHANGE': {
        // Matches TickerMigrator.TickerMigrationParams struct:
        // (address newToken, string newTicker, string newName,
        //  bytes32 merkleRoot, uint256 snapshotBlock, uint256 claimDeadline)
        return coder.encode(
          ['address', 'string', 'string', 'bytes32', 'uint256', 'uint256'],
          [
            params.newToken || params.new_token || ethers.ZeroAddress,
            params.newTicker || params.new_ticker || '',
            params.newName || params.new_name || '',
            params.merkleRoot || ethers.ZeroHash,
            params.snapshotBlock || params.snapshot_block || 0,
            params.claimDeadline || params.claim_deadline || 0,
          ]
        );
      }

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
