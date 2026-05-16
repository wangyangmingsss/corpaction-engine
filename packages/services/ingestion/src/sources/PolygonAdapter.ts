import { ICorporateActionSource, RawCorporateActionEvent } from './ICorporateActionSource';
import { Logger } from '../utils/Logger';
import crypto from 'crypto';
import WebSocket from 'ws';

export class PolygonAdapter implements ICorporateActionSource {
  readonly name = 'POLYGON';
  readonly reliability = 90;

  private apiKey: string;
  private logger: Logger;
  private readonly BASE_URL = 'https://api.polygon.io';
  private readonly WS_URL = 'wss://socket.polygon.io/stocks';
  private ws: WebSocket | null = null;
  private wsReconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private eventCallback: ((event: RawCorporateActionEvent) => void) | null = null;

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
    try {
      const parts = eventId.replace('POLYGON:', '').split(':');
      const type = parts[0]; // DIV or SPLIT
      const ticker = parts[1];
      const date = parts[2];

      if (!ticker || !date) {
        return { verified: false, details: 'Event ID missing required ticker or date' };
      }

      let url: string;
      if (type === 'DIV') {
        url = `${this.BASE_URL}/v3/reference/dividends?ticker=${ticker}&ex_dividend_date=${date}&apiKey=${this.apiKey}`;
      } else {
        url = `${this.BASE_URL}/v3/reference/splits?ticker=${ticker}&execution_date=${date}&apiKey=${this.apiKey}`;
      }

      const response = await fetch(url);
      if (!response.ok) {
        return { verified: false, details: `Polygon API returned HTTP ${response.status}` };
      }

      const data = await response.json() as { results?: Array<Record<string, unknown>> };
      const results = data.results || [];

      if (results.length === 0) {
        return { verified: false, details: `No ${type} data found for ${ticker} on ${date}` };
      }

      const record = results[0];

      if (type === 'DIV') {
        const amount = Number(record.cash_amount);
        if (isNaN(amount) || amount <= 0 || amount > 1000) {
          return { verified: false, details: `Dividend amount out of range: ${amount}` };
        }
      } else if (type === 'SPLIT') {
        const splitFrom = Number(record.split_from);
        const splitTo = Number(record.split_to);
        if (isNaN(splitFrom) || isNaN(splitTo) || splitFrom <= 0 || splitTo <= 0) {
          return { verified: false, details: `Invalid split ratio: ${splitFrom}:${splitTo}` };
        }
      }

      return { verified: true, details: `Polygon event ${eventId} verified with matching data` };
    } catch (error) {
      return { verified: false, details: `Polygon verification error: ${String(error)}` };
    }
  }

  subscribe(callback: (event: RawCorporateActionEvent) => void): void {
    this.eventCallback = callback;
    this.connectWebSocket();
  }

  private connectWebSocket(): void {
    if (this.ws) {
      this.ws.removeAllListeners();
      this.ws.close();
    }

    this.ws = new WebSocket(this.WS_URL);

    this.ws.on('open', () => {
      this.logger.info('Polygon WebSocket connected');
      // Authenticate
      this.ws?.send(JSON.stringify({ action: 'auth', params: this.apiKey }));
    });

    this.ws.on('message', (data: WebSocket.Data) => {
      try {
        const messages = JSON.parse(data.toString()) as Array<Record<string, unknown>>;
        for (const msg of messages) {
          if (msg.ev === 'status' && msg.status === 'auth_success') {
            // Subscribe to corporate action events after authentication
            this.ws?.send(JSON.stringify({ action: 'subscribe', params: 'CA.*' }));
            this.logger.info('Subscribed to Polygon corporate action events');
          } else if (msg.ev === 'CA') {
            this.handleRealtimeEvent(msg);
          }
        }
      } catch (error) {
        this.logger.error('Polygon WebSocket message parse error', { error: String(error) });
      }
    });

    this.ws.on('close', () => {
      this.logger.warn('Polygon WebSocket disconnected, reconnecting in 5s');
      this.scheduleReconnect();
    });

    this.ws.on('error', (error: Error) => {
      this.logger.error('Polygon WebSocket error', { error: error.message });
    });
  }

  private scheduleReconnect(): void {
    if (this.wsReconnectTimer) clearTimeout(this.wsReconnectTimer);
    this.wsReconnectTimer = setTimeout(() => this.connectWebSocket(), 5000);
  }

  private handleRealtimeEvent(msg: Record<string, unknown>): void {
    if (!this.eventCallback) return;

    const ticker = String(msg.sym || msg.ticker || '');
    const eventType = this.mapRealtimeEventType(String(msg.type || ''));
    const contentHash = crypto.createHash('sha256').update(JSON.stringify(msg)).digest('hex');

    const event: RawCorporateActionEvent = {
      sourceType: this.name,
      sourceId: `POLYGON:RT:${ticker}:${Date.now()}`,
      contentHash,
      ticker,
      eventType,
      rawData: msg,
      detectedAt: new Date(),
    };

    this.eventCallback(event);
  }

  private mapRealtimeEventType(type: string): string {
    const mapping: Record<string, string> = {
      dividend: 'DIVIDEND',
      split: 'SPLIT',
      merger: 'MERGER_REGISTRATION',
      spinoff: 'SPINOFF',
      acquisition: 'MERGER_REGISTRATION',
    };
    return mapping[type.toLowerCase()] || 'CORPORATE_EVENT';
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
