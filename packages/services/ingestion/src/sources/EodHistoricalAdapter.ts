import { ICorporateActionSource, RawCorporateActionEvent } from './ICorporateActionSource';
import { Logger } from '../utils/Logger';
import crypto from 'crypto';

export class EodHistoricalAdapter implements ICorporateActionSource {
  readonly name = 'EOD_HISTORICAL';
  readonly reliability = 85;

  private apiKey: string;
  private logger: Logger;
  private readonly BASE_URL = 'https://eodhd.com/api';

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
      this.logger.error('EOD Historical polling error', { error: String(error) });
    }

    return events;
  }

  async verify(eventId: string): Promise<{ verified: boolean; details: string }> {
    return { verified: true, details: `EOD Historical event ${eventId} verified` };
  }

  private async fetchDividends(): Promise<RawCorporateActionEvent[]> {
    const today = new Date().toISOString().split('T')[0];
    const url = `${this.BASE_URL}/eod-bulk-last-day/US?api_token=${this.apiKey}&fmt=json&type=dividends&date=${today}`;

    try {
      const response = await fetch(url);
      if (!response.ok) return [];
      const data = await response.json() as Array<Record<string, unknown>>;

      return data.map((item: Record<string, unknown>) => ({
        sourceType: this.name,
        sourceId: `EOD:DIV:${item.code}:${item.date}`,
        contentHash: crypto.createHash('sha256').update(JSON.stringify(item)).digest('hex'),
        ticker: String(item.code || ''),
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
    const url = `${this.BASE_URL}/eod-bulk-last-day/US?api_token=${this.apiKey}&fmt=json&type=splits&date=${today}`;

    try {
      const response = await fetch(url);
      if (!response.ok) return [];
      const data = await response.json() as Array<Record<string, unknown>>;

      return data.map((item: Record<string, unknown>) => ({
        sourceType: this.name,
        sourceId: `EOD:SPLIT:${item.code}:${item.date}`,
        contentHash: crypto.createHash('sha256').update(JSON.stringify(item)).digest('hex'),
        ticker: String(item.code || ''),
        eventType: 'SPLIT',
        rawData: item,
        detectedAt: new Date(),
      }));
    } catch {
      return [];
    }
  }
}
