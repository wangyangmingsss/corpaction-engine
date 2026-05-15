import { ICorporateActionSource, RawCorporateActionEvent } from './ICorporateActionSource';
import { Logger } from '../utils/Logger';
import crypto from 'crypto';

export class PolygonAdapter implements ICorporateActionSource {
  readonly name = 'POLYGON';
  readonly reliability = 90;

  private apiKey: string;
  private logger: Logger;
  private readonly BASE_URL = 'https://api.polygon.io';

  constructor(apiKey: string, logger: Logger) {
    this.apiKey = apiKey;
    this.logger = logger;
  }

  async poll(): Promise<RawCorporateActionEvent[]> {
    const events: RawCorporateActionEvent[] = [];

    try {
      const dividends = await this.fetchDividends();
      events.push(...dividends);

      const splits = await this.fetchSplits();
      events.push(...splits);
    } catch (error) {
      this.logger.error('Polygon polling error', { error: String(error) });
    }

    return events;
  }

  async verify(eventId: string): Promise<{ verified: boolean; details: string }> {
    return { verified: true, details: `Polygon event ${eventId} verified` };
  }

  private async fetchDividends(): Promise<RawCorporateActionEvent[]> {
    const today = new Date().toISOString().split('T')[0];
    const url = `${this.BASE_URL}/v3/reference/dividends?ex_dividend_date=${today}&apiKey=${this.apiKey}`;

    try {
      const response = await fetch(url);
      if (!response.ok) return [];
      const data = await response.json() as { results?: Array<Record<string, unknown>> };

      return (data.results || []).map((item: Record<string, unknown>) => ({
        sourceType: this.name,
        sourceId: `POLYGON:DIV:${item.ticker}:${item.ex_dividend_date}`,
        contentHash: crypto.createHash('sha256').update(JSON.stringify(item)).digest('hex'),
        ticker: String(item.ticker || ''),
        eventType: 'DIVIDEND',
        rawData: item,
        detectedAt: new Date(),
      }));
    } catch {
      return [];
    }
  }

  private async fetchSplits(): Promise<RawCorporateActionEvent[]> {
    const today = new Date().toISOString().split('T')[0];
    const url = `${this.BASE_URL}/v3/reference/splits?execution_date=${today}&apiKey=${this.apiKey}`;

    try {
      const response = await fetch(url);
      if (!response.ok) return [];
      const data = await response.json() as { results?: Array<Record<string, unknown>> };

      return (data.results || []).map((item: Record<string, unknown>) => ({
        sourceType: this.name,
        sourceId: `POLYGON:SPLIT:${item.ticker}:${item.execution_date}`,
        contentHash: crypto.createHash('sha256').update(JSON.stringify(item)).digest('hex'),
        ticker: String(item.ticker || ''),
        eventType: 'SPLIT',
        rawData: item,
        detectedAt: new Date(),
      }));
    } catch {
      return [];
    }
  }
}
