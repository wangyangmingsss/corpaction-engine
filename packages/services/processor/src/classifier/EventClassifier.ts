import { RawCorporateActionEvent } from '../types/CorporateActionTypes';
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

// 8-K Item codes that map to specific corporate action categories
const ITEM_8K_MAP: Record<string, { actionHint: string; signal: string }> = {
  '1.01': { actionHint: 'MERGER_REGISTRATION', signal: 'item_1.01_material_agreement' },
  '1.02': { actionHint: 'DELISTING', signal: 'item_1.02_termination_agreement' },
  '2.01': { actionHint: 'MERGER_REGISTRATION', signal: 'item_2.01_acquisition_disposition' },
  '3.03': { actionHint: 'TICKER_CHANGE', signal: 'item_3.03_material_modification_rights' },
  '5.01': { actionHint: 'TICKER_CHANGE', signal: 'item_5.01_change_control' },
  '5.03': { actionHint: 'FORWARD_SPLIT', signal: 'item_5.03_amendments_articles' },
  '8.01': { actionHint: 'CORPORATE_EVENT', signal: 'item_8.01_other_events' },
};

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
    if (event.eventType === 'MERGER_REGISTRATION') {
      return this.classifyMerger(event);
    }
    if (event.eventType === 'TENDER_OFFER') {
      return this.classifyTenderOffer(event);
    }
    if (event.eventType === 'LIQUIDATION' || this.hasLiquidationSignals(event)) {
      return this.classifyLiquidation(event);
    }
    if (event.eventType === 'TICKER_CHANGE' || this.hasTickerChangeSignals(event)) {
      return this.classifyTickerChange(event);
    }
    if (event.eventType === 'DELISTING') {
      return this.classifyDelisting(event);
    }
    if (event.eventType === 'PROXY_VOTE') {
      return this.classifyProxyVote(event);
    }
    if (event.eventType === 'CORPORATE_EVENT') {
      return this.classifyCorporateEvent(event);
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

  private classifyTenderOffer(event: RawCorporateActionEvent): ClassificationResult {
    const rawData = event.rawData;
    const hasExchangeRatio = !!rawData.exchange_ratio;
    const offerPrice = rawData.offer_price || rawData.cash_per_share;

    let actionType: ActionType = 'MERGER_CASH';
    const signals = ['sc_to_t_filing', 'tender_offer'];

    if (hasExchangeRatio && offerPrice) {
      actionType = 'MERGER_HYBRID';
      signals.push('exchange_ratio', 'cash_component');
    } else if (hasExchangeRatio) {
      actionType = 'MERGER_STOCK';
      signals.push('exchange_ratio');
    } else {
      signals.push('cash_tender');
    }

    return {
      actionType,
      confidence: offerPrice ? 'HIGH' : 'MEDIUM',
      signals,
      params: {
        ...rawData,
        offerPrice,
        isTenderOffer: true,
      },
    };
  }

  private classifyLiquidation(event: RawCorporateActionEvent): ClassificationResult {
    const rawData = event.rawData;
    const distributionAmount = rawData.distribution_amount || rawData.liquidation_value;

    return {
      actionType: 'LIQUIDATION',
      confidence: distributionAmount ? 'HIGH' : 'MEDIUM',
      signals: ['liquidation_filing', distributionAmount ? 'distribution_amount_present' : 'distribution_amount_missing'],
      params: {
        distributionAmount,
        effectiveDate: rawData.effective_date,
        isVoluntary: rawData.is_voluntary ?? false,
      },
    };
  }

  private classifyDelisting(event: RawCorporateActionEvent): ClassificationResult {
    if (this.hasLiquidationSignals(event)) {
      return this.classifyLiquidation(event);
    }

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

    if (rawText.includes('liquidat') || rawText.includes('wind down') || rawText.includes('dissolution')) {
      return this.classifyLiquidation(event);
    }

    return {
      actionType: 'MERGER_STOCK',
      confidence: 'LOW',
      signals: ['proxy_vote', 'merger_vote'],
      params: event.rawData,
    };
  }

  private classifyCorporateEvent(event: RawCorporateActionEvent): ClassificationResult | null {
    const rawData = event.rawData;
    const rawText = JSON.stringify(rawData).toLowerCase();

    const detectedItems = this.detect8KItems(rawData, rawText);

    if (detectedItems.length > 0) {
      const primaryItem = detectedItems[0];
      const itemInfo = ITEM_8K_MAP[primaryItem];

      if (itemInfo) {
        if (primaryItem === '1.01') {
          return this.classifyMerger(event);
        }

        if (primaryItem === '5.03') {
          if (this.hasSplitSignals(event)) {
            return this.classifySplit(event);
          }
          if (this.hasTickerChangeSignals(event)) {
            return this.classifyTickerChange(event);
          }
          return {
            actionType: 'TICKER_CHANGE',
            confidence: 'LOW',
            signals: [itemInfo.signal, ...detectedItems.map(i => `item_${i}`)],
            params: { ...rawData, detectedItems },
          };
        }

        if (primaryItem === '8.01') {
          if (this.hasDividendSignals(event)) return this.classifyDividend(event);
          if (this.hasSplitSignals(event)) return this.classifySplit(event);
          if (this.hasLiquidationSignals(event)) return this.classifyLiquidation(event);
        }
      }
    }

    if (this.hasDividendSignals(event)) return this.classifyDividend(event);
    if (this.hasSplitSignals(event)) return this.classifySplit(event);
    if (this.hasLiquidationSignals(event)) return this.classifyLiquidation(event);

    this.logger.warn('CORPORATE_EVENT could not be refined', {
      ticker: event.ticker,
      detectedItems,
    });
    return null;
  }

  private detect8KItems(rawData: Record<string, unknown>, rawText: string): string[] {
    const items: string[] = [];

    if (Array.isArray(rawData.items)) {
      for (const item of rawData.items) {
        if (typeof item === 'string' && ITEM_8K_MAP[item]) {
          items.push(item);
        }
      }
    }

    for (const itemCode of Object.keys(ITEM_8K_MAP)) {
      const patterns = [
        `item ${itemCode}`,
        `item${itemCode.replace('.', '')}`,
        `"${itemCode}"`,
      ];
      for (const pattern of patterns) {
        if (rawText.includes(pattern)) {
          if (!items.includes(itemCode)) items.push(itemCode);
          break;
        }
      }
    }

    return items;
  }

  private hasDividendSignals(event: RawCorporateActionEvent): boolean {
    const raw = JSON.stringify(event.rawData).toLowerCase();
    return raw.includes('dividend') || raw.includes('distribution') || raw.includes('cash_amount');
  }

  private hasSplitSignals(event: RawCorporateActionEvent): boolean {
    const raw = JSON.stringify(event.rawData).toLowerCase();
    return raw.includes('split') || raw.includes('stock split');
  }

  private hasLiquidationSignals(event: RawCorporateActionEvent): boolean {
    const raw = JSON.stringify(event.rawData).toLowerCase();
    return raw.includes('liquidat') || raw.includes('dissolution') || raw.includes('wind down') || raw.includes('winding up');
  }

  private hasTickerChangeSignals(event: RawCorporateActionEvent): boolean {
    const raw = JSON.stringify(event.rawData).toLowerCase();
    return (
      raw.includes('ticker change') ||
      raw.includes('ticker symbol change') ||
      raw.includes('name change') ||
      raw.includes('new ticker') ||
      raw.includes('symbol change') ||
      raw.includes('cusip change') ||
      (raw.includes('trading symbol') && raw.includes('chang'))
    );
  }

  private classifyTickerChange(event: RawCorporateActionEvent): ClassificationResult {
    const rawData = event.rawData;
    const rawText = JSON.stringify(rawData).toLowerCase();

    const signals: string[] = ['ticker_change'];
    let confidence: ConfidenceLevel = 'MEDIUM';

    // High confidence if we have both old and new ticker information
    const hasOldTicker = !!(rawData.old_ticker || rawData.previous_ticker);
    const hasNewTicker = !!(rawData.new_ticker || rawData.new_symbol);
    if (hasOldTicker && hasNewTicker) {
      confidence = 'HIGH';
      signals.push('old_and_new_ticker_present');
    } else if (rawText.includes('ticker symbol change') || rawText.includes('cusip change')) {
      confidence = 'HIGH';
      signals.push('explicit_ticker_change_language');
    }

    if (rawData.effective_date) {
      signals.push('effective_date_present');
    }

    return {
      actionType: 'TICKER_CHANGE',
      confidence,
      signals,
      params: {
        oldTicker: rawData.old_ticker || rawData.previous_ticker,
        newTicker: rawData.new_ticker || rawData.new_symbol,
        effectiveDate: rawData.effective_date,
      },
    };
  }
}
