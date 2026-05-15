import { RawCorporateActionEvent } from '../sources/ICorporateActionSource';
import { Logger } from '../utils/Logger';

export type ActionType =
  | 'DIVIDEND'
  | 'FORWARD_SPLIT'
  | 'REVERSE_SPLIT'
  | 'MERGER_CASH'
  | 'MERGER_STOCK'
  | 'MERGER_HYBRID'
  | 'SPINOFF'
  | 'DELISTING'
  | 'LIQUIDATION'
  | 'TICKER_CHANGE';

export type ConfidenceLevel = 'LOW' | 'MEDIUM' | 'HIGH';

export interface ClassificationResult {
  actionType: ActionType;
  confidence: ConfidenceLevel;
  signals: string[];
  params: Record<string, unknown>;
}

export class EventClassifier {
  private logger: Logger;

  constructor(logger: Logger) {
    this.logger = logger;
  }

  classify(event: RawCorporateActionEvent): ClassificationResult | null {
    if (event.eventType === 'DIVIDEND' || this.hasDividendSignals(event)) {
      return this.classifyDividend(event);
    }
    if (event.eventType === 'SPLIT' || this.hasSplitSignals(event)) {
      return this.classifySplit(event);
    }
    if (event.eventType === 'MERGER_REGISTRATION' || event.eventType === 'TENDER_OFFER') {
      return this.classifyMerger(event);
    }
    if (event.eventType === 'DELISTING') {
      return this.classifyDelisting(event);
    }
    if (event.eventType === 'PROXY_VOTE') {
      return this.classifyProxyVote(event);
    }

    this.logger.warn('Unable to classify event', { ticker: event.ticker, eventType: event.eventType });
    return null;
  }

  private classifyDividend(event: RawCorporateActionEvent): ClassificationResult {
    const rawData = event.rawData;
    const amount = rawData.dividend || rawData.cash_amount || rawData.amount;
    const payDate = rawData.pay_date || rawData.payment_date;

    return {
      actionType: 'DIVIDEND',
      confidence: amount && payDate ? 'HIGH' : 'MEDIUM',
      signals: ['dividend_keywords', amount ? 'amount_present' : 'amount_missing'],
      params: { amount, payDate, exDate: rawData.ex_date || rawData.ex_dividend_date },
    };
  }

  private classifySplit(event: RawCorporateActionEvent): ClassificationResult {
    const rawData = event.rawData;
    const split = String(rawData.split || rawData.ratio || '');
    const parts = split.split(/[:/]/);
    const numerator = parseInt(parts[0]) || 0;
    const denominator = parseInt(parts[1]) || 0;

    const isReverse = numerator < denominator;

    return {
      actionType: isReverse ? 'REVERSE_SPLIT' : 'FORWARD_SPLIT',
      confidence: numerator > 0 && denominator > 0 ? 'HIGH' : 'MEDIUM',
      signals: ['split_ratio', isReverse ? 'reverse' : 'forward'],
      params: { numerator, denominator, isReverse },
    };
  }

  private classifyMerger(event: RawCorporateActionEvent): ClassificationResult {
    const rawData = event.rawData;
    const hasExchangeRatio = !!rawData.exchange_ratio;
    const hasCashConsideration = !!rawData.cash_per_share;

    let actionType: ActionType = 'MERGER_CASH';
    if (hasExchangeRatio && hasCashConsideration) actionType = 'MERGER_HYBRID';
    else if (hasExchangeRatio) actionType = 'MERGER_STOCK';

    return {
      actionType,
      confidence: 'MEDIUM',
      signals: ['merger_filing', hasExchangeRatio ? 'exchange_ratio' : 'cash_only'],
      params: rawData,
    };
  }

  private classifyDelisting(event: RawCorporateActionEvent): ClassificationResult {
    return {
      actionType: 'DELISTING',
      confidence: 'HIGH',
      signals: ['25-NSE_filing', 'regulatory'],
      params: { effectiveDate: event.rawData.effective_date },
    };
  }

  private classifyProxyVote(event: RawCorporateActionEvent): ClassificationResult {
    const rawText = JSON.stringify(event.rawData).toLowerCase();

    if (rawText.includes('spin-off') || rawText.includes('spinoff')) {
      return {
        actionType: 'SPINOFF',
        confidence: 'MEDIUM',
        signals: ['proxy_vote', 'spinoff_keywords'],
        params: event.rawData,
      };
    }

    return {
      actionType: 'MERGER_STOCK',
      confidence: 'LOW',
      signals: ['proxy_vote', 'merger_vote'],
      params: event.rawData,
    };
  }

  private hasDividendSignals(event: RawCorporateActionEvent): boolean {
    const raw = JSON.stringify(event.rawData).toLowerCase();
    return raw.includes('dividend') || raw.includes('distribution') || raw.includes('cash_amount');
  }

  private hasSplitSignals(event: RawCorporateActionEvent): boolean {
    const raw = JSON.stringify(event.rawData).toLowerCase();
    return raw.includes('split') || raw.includes('stock split');
  }
}
