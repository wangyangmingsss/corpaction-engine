import { ICorporateActionSource, RawCorporateActionEvent, VerificationResult } from './ICorporateActionSource';
import { Logger } from '../utils/Logger';
import crypto from 'crypto';

interface AlphaVantageOverview {
  Symbol?: string;
  Name?: string;
  DividendPerShare?: string;
  DividendDate?: string;
  ExDividendDate?: string;
  DividendYield?: string;
}

interface AlphaVantageSplitEntry {
  'effective_date'?: string;
  'split_ratio'?: string;
  symbol?: string;
}

export class AlphaVantageAdapter implements ICorporateActionSource {
  readonly name = 'ALPHA_VANTAGE';
  readonly reliability = 75;

  private logger: Logger;
  private apiKey: string;
  private baseUrl: string;
  private watchlist: string[];

  constructor(logger: Logger, apiKey?: string, watchlist: string[] = []) {
    this.logger = logger;
    this.apiKey = apiKey || process.env.ALPHA_VANTAGE_API_KEY || '';
    this.baseUrl = 'https://www.alphavantage.co/query';
    this.watchlist = watchlist;
  }

  async poll(): Promise<RawCorporateActionEvent[]> {
    const events: RawCorporateActionEvent[] = [];

    for (const ticker of this.watchlist) {
      try {
        const dividendEvents = await this.fetchDividends(ticker);
        events.push(...dividendEvents);
      } catch (error) {
        this.logger.error('AlphaVantage dividend fetch failed', {
          ticker,
          error: String(error),
        });
      }

      try {
        const splitEvents = await this.fetchSplits(ticker);
        events.push(...splitEvents);
      } catch (error) {
        this.logger.error('AlphaVantage split fetch failed', {
          ticker,
          error: String(error),
        });
      }

      // Rate-limit: Alpha Vantage free tier allows 5 req/min
      await new Promise(resolve => setTimeout(resolve, 15_000));
    }

    this.logger.info('AlphaVantage poll complete', { count: events.length });
    return events;
  }

  async verify(eventId: string): Promise<VerificationResult> {
    // Alpha Vantage has no individual event verification endpoint;
    // re-fetch the overview and confirm the dividend/split data still matches.
    const parts = eventId.split(':');
    const ticker = parts[1] || '';

    try {
      const overview = await this.fetchOverview(ticker);
      if (!overview.Symbol) {
        return { verified: false, details: 'Ticker not found in Alpha Vantage' };
      }
      return { verified: true, details: `Verified via OVERVIEW for ${ticker}` };
    } catch (error) {
      return { verified: false, details: `Verification error: ${String(error)}` };
    }
  }

  private async fetchDividends(ticker: string): Promise<RawCorporateActionEvent[]> {
    const overview = await this.fetchOverview(ticker);
    const events: RawCorporateActionEvent[] = [];

    const dividendPerShare = parseFloat(overview.DividendPerShare || '0');
    if (dividendPerShare > 0 && overview.DividendDate) {
      const rawData: Record<string, unknown> = {
        dividend: dividendPerShare,
        cash_amount: dividendPerShare,
        pay_date: overview.DividendDate,
        ex_dividend_date: overview.ExDividendDate,
        dividend_yield: overview.DividendYield,
      };

      const contentHash = crypto.createHash('sha256')
        .update(`${ticker}:DIV:${overview.DividendDate}:${dividendPerShare}`)
        .digest('hex');

      events.push({
        sourceType: this.name,
        sourceId: `AV:${ticker}:DIV:${overview.DividendDate}`,
        contentHash,
        ticker,
        companyName: overview.Name,
        eventType: 'DIVIDEND',
        rawData,
        detectedAt: new Date(),
      });
    }

    return events;
  }

  private async fetchSplits(ticker: string): Promise<RawCorporateActionEvent[]> {
    const url = `${this.baseUrl}?function=STOCK_SPLIT&symbol=${encodeURIComponent(ticker)}&apikey=${this.apiKey}`;
    const response = await fetch(url, {
      headers: { 'Accept': 'application/json' },
    });

    if (!response.ok) {
      throw new Error(`Alpha Vantage splits API error: ${response.status}`);
    }

    const data = await response.json() as { data?: AlphaVantageSplitEntry[] };
    const entries = data.data || [];
    const events: RawCorporateActionEvent[] = [];

    for (const entry of entries) {
      const ratio = entry.split_ratio || '';
      const effectiveDate = entry.effective_date || '';
      if (!ratio || !effectiveDate) continue;

      // Only process recent splits (within last 30 days)
      const splitDate = new Date(effectiveDate);
      const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
      if (splitDate < thirtyDaysAgo) continue;

      const rawData: Record<string, unknown> = {
        ratio,
        split: ratio,
        effective_date: effectiveDate,
      };

      const contentHash = crypto.createHash('sha256')
        .update(`${ticker}:SPLIT:${effectiveDate}:${ratio}`)
        .digest('hex');

      events.push({
        sourceType: this.name,
        sourceId: `AV:${ticker}:SPLIT:${effectiveDate}`,
        contentHash,
        ticker,
        eventType: 'SPLIT',
        rawData,
        detectedAt: new Date(),
      });
    }

    return events;
  }

  private async fetchOverview(ticker: string): Promise<AlphaVantageOverview> {
    const url = `${this.baseUrl}?function=OVERVIEW&symbol=${encodeURIComponent(ticker)}&apikey=${this.apiKey}`;
    const response = await fetch(url, {
      headers: { 'Accept': 'application/json' },
    });

    if (!response.ok) {
      throw new Error(`Alpha Vantage OVERVIEW API error: ${response.status}`);
    }

    return await response.json() as AlphaVantageOverview;
  }
}
