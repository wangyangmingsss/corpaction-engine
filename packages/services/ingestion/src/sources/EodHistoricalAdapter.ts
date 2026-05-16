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
    try {
      const parts = eventId.replace('EOD:', '').split(':');
      const type = parts[0]; // DIV or SPLIT
      const ticker = parts[1];
      const date = parts[2];

      if (!ticker || !date) {
        return { verified: false, details: 'Event ID missing required ticker or date' };
      }

      const endpoint = type === 'DIV' ? 'dividends' : 'splits';
      const url = `${this.BASE_URL}/${endpoint}/${ticker}.US?api_token=${this.apiKey}&fmt=json&from=${date}&to=${date}`;
      const response = await fetch(url);

      if (!response.ok) {
        return { verified: false, details: `EOD API returned HTTP ${response.status}` };
      }

      const data = await response.json() as Array<Record<string, unknown>>;

      if (!Array.isArray(data) || data.length === 0) {
        return { verified: false, details: `No ${type} data found for ${ticker} on ${date}` };
      }

      const record = data[0];

      if (type === 'DIV') {
        const amount = Number(record.value ?? record.dividend);
        if (isNaN(amount) || amount <= 0 || amount > 1000) {
          return { verified: false, details: `Dividend amount out of range: ${amount}` };
        }
      } else if (type === 'SPLIT') {
        const split = String(record.split || '');
        const splitParts = split.split('/');
        const num = parseFloat(splitParts[0]);
        const den = parseFloat(splitParts[1]);
        if (isNaN(num) || isNaN(den) || num <= 0 || den <= 0) {
          return { verified: false, details: `Invalid split ratio: ${split}` };
        }
      }

      return { verified: true, details: `EOD Historical event ${eventId} verified with matching data` };
    } catch (error) {
      return { verified: false, details: `EOD Historical verification error: ${String(error)}` };
    }
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
