import { ICorporateActionSource, RawCorporateActionEvent } from './ICorporateActionSource';
import { Logger } from '../utils/Logger';
import { Redis } from 'ioredis';
import crypto from 'crypto';

interface EdgarFiling {
  accessionNumber: string;
  filingDate: string;
  form: string;
  fileUrl: string;
  companyName: string;
  cik: string;
  ticker: string;
}

export class EdgarMonitor implements ICorporateActionSource {
  readonly name = 'SEC_EDGAR';
  readonly reliability = 95;

  private readonly EDGAR_FULL_TEXT_URL = 'https://efts.sec.gov/LATEST/search-index';
  private readonly RELEVANT_FORMS = ['8-K', '14A', 'S-4', 'SC TO-T', '25-NSE'];
  private readonly POLL_INTERVAL_MARKET = 60_000;
  private readonly POLL_INTERVAL_OFF = 300_000;

  private readonly RSS_FEED_URL =
    'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&type=8-K&dateb=&owner=include&count=40&search_text=&action=getcompany&output=atom';
  private readonly MAX_CONSECUTIVE_FAILURES = 3;

  private redis: Redis;
  private logger: Logger;
  private isRunning = false;
  private consecutiveFailures = 0;
  private useRssFallback = false;

  constructor(redis: Redis, logger: Logger) {
    this.redis = redis;
    this.logger = logger;
  }

  async start(): Promise<void> {
    this.isRunning = true;
    this.logger.info('EdgarMonitor started');
    this.pollLoop();
  }

  async stop(): Promise<void> {
    this.isRunning = false;
  }

  async poll(): Promise<RawCorporateActionEvent[]> {
    const events: RawCorporateActionEvent[] = [];

    // If RSS fallback is active, use the RSS feed instead of the API
    if (this.useRssFallback) {
      this.logger.warn('Using RSS fallback for EDGAR polling');
      try {
        const rssEvents = await this.pollRssFeed();
        // On RSS success, attempt to recover API on next cycle
        this.consecutiveFailures = 0;
        return rssEvents;
      } catch (rssError) {
        this.logger.error('RSS fallback also failed', { error: String(rssError) });
        return [];
      }
    }

    for (const form of this.RELEVANT_FORMS) {
      try {
        const filings = await this.fetchRecentFilings(form);
        // Reset failure counter on any successful fetch
        this.consecutiveFailures = 0;
        this.useRssFallback = false;

        for (const filing of filings) {
          const processed = await this.redis.sismember(
            'edgar:processed', filing.accessionNumber
          );
          if (processed) continue;

          const event = await this.parseFilingToEvent(filing);
          if (event) {
            events.push(event);
            await this.redis.sadd('edgar:processed', filing.accessionNumber);
          }
        }
      } catch (error) {
        this.consecutiveFailures++;
        this.logger.error(`Error fetching ${form} filings (failure ${this.consecutiveFailures}/${this.MAX_CONSECUTIVE_FAILURES})`, {
          error: String(error),
        });

        if (this.consecutiveFailures >= this.MAX_CONSECUTIVE_FAILURES) {
          this.useRssFallback = true;
          this.logger.warn('Switching to RSS fallback after consecutive API failures', {
            consecutiveFailures: this.consecutiveFailures,
          });
          // Immediately try RSS for this poll cycle
          try {
            const rssEvents = await this.pollRssFeed();
            events.push(...rssEvents);
          } catch (rssError) {
            this.logger.error('RSS fallback failed on first attempt', { error: String(rssError) });
          }
          break;
        }
      }
    }
    return events;
  }

  async verify(eventId: string): Promise<{ verified: boolean; details: string }> {
    const accession = eventId.split(':')[1];
    const filing = await this.fetchFiling(accession);
    if (!filing) return { verified: false, details: 'Filing not found' };
    return { verified: true, details: `Filing verified: ${accession}` };
  }

  private async pollLoop(): Promise<void> {
    while (this.isRunning) {
      const interval = this.isMarketHours()
        ? this.POLL_INTERVAL_MARKET
        : this.POLL_INTERVAL_OFF;

      try {
        const events = await this.poll();
        if (events.length > 0) {
          this.logger.info(`Ingested ${events.length} events from EDGAR`);
          for (const event of events) {
            await this.redis.xadd(
              'corpaction:raw_events', '*',
              'source', this.name,
              'data', JSON.stringify(event)
            );
          }
        }
      } catch (error) {
        this.logger.error('Poll loop error', { error: String(error) });
      }

      await new Promise(resolve => setTimeout(resolve, interval));
    }
  }

  private isMarketHours(): boolean {
    const now = new Date();
    const etHour = now.getUTCHours() - 4;
    return etHour >= 9 && etHour <= 18;
  }

  private async fetchRecentFilings(form: string): Promise<EdgarFiling[]> {
    const today = new Date().toISOString().split('T')[0];
    const url = `${this.EDGAR_FULL_TEXT_URL}?q=*&dateRange=custom&startdt=${today}&enddt=${today}&forms=${form}`;

    const response = await fetch(url, {
      headers: {
        'User-Agent': process.env.EDGAR_USER_AGENT || 'CorpActionEngine/1.0',
        'Accept': 'application/json',
      },
    });

    if (!response.ok) {
      throw new Error(`EDGAR API error: ${response.status}`);
    }

    const data = await response.json() as { hits?: { hits?: Array<{ _source: Record<string, string> }> } };
    const hits = data.hits?.hits || [];

    return hits.map((hit: { _source: Record<string, string> }) => ({
      accessionNumber: hit._source.accession_no || '',
      filingDate: hit._source.file_date || '',
      form: hit._source.form_type || form,
      fileUrl: `https://www.sec.gov/Archives/edgar/data/${hit._source.cik}/${hit._source.accession_no}`,
      companyName: hit._source.entity_name || '',
      cik: hit._source.cik || '',
      ticker: hit._source.ticker || '',
    }));
  }

  private async parseFilingToEvent(filing: EdgarFiling): Promise<RawCorporateActionEvent | null> {
    const contentHash = crypto.createHash('sha256')
      .update(JSON.stringify(filing))
      .digest('hex');

    return {
      sourceType: this.name,
      sourceId: `EDGAR:${filing.accessionNumber}`,
      sourceUrl: filing.fileUrl,
      contentHash,
      ticker: filing.ticker,
      companyName: filing.companyName,
      eventType: this.classifyForm(filing.form),
      rawData: filing as unknown as Record<string, unknown>,
      detectedAt: new Date(),
    };
  }

  private classifyForm(form: string): string | undefined {
    const mapping: Record<string, string> = {
      '8-K': 'CORPORATE_EVENT',
      '14A': 'PROXY_VOTE',
      'S-4': 'MERGER_REGISTRATION',
      'SC TO-T': 'TENDER_OFFER',
      '25-NSE': 'DELISTING',
    };
    return mapping[form];
  }

  private async pollRssFeed(): Promise<RawCorporateActionEvent[]> {
    const events: RawCorporateActionEvent[] = [];

    const response = await fetch(this.RSS_FEED_URL, {
      headers: {
        'User-Agent': process.env.EDGAR_USER_AGENT || 'CorpActionEngine/1.0',
        'Accept': 'application/atom+xml',
      },
    });

    if (!response.ok) {
      throw new Error(`EDGAR RSS feed error: ${response.status}`);
    }

    const text = await response.text();

    // Simple Atom XML parsing for <entry> elements
    const entryRegex = /<entry>([\s\S]*?)<\/entry>/g;
    let match: RegExpExecArray | null;

    while ((match = entryRegex.exec(text)) !== null) {
      const entry = match[1];
      const title = this.extractXmlTag(entry, 'title');
      const link = this.extractXmlAttr(entry, 'link', 'href');
      const updated = this.extractXmlTag(entry, 'updated');
      const summary = this.extractXmlTag(entry, 'summary');

      // Extract accession number from the link URL
      const accessionMatch = link?.match(/(\d{10}-\d{2}-\d{6})/);
      const accessionNumber = accessionMatch ? accessionMatch[1] : '';

      if (!accessionNumber) continue;

      const processed = await this.redis.sismember('edgar:processed', accessionNumber);
      if (processed) continue;

      // Try to extract ticker from the title
      const tickerMatch = title?.match(/\(([A-Z]{1,5})\)/);
      const ticker = tickerMatch ? tickerMatch[1] : '';

      const contentHash = crypto.createHash('sha256')
        .update(`${accessionNumber}:${updated}`)
        .digest('hex');

      events.push({
        sourceType: this.name,
        sourceId: `EDGAR:${accessionNumber}`,
        sourceUrl: link || undefined,
        contentHash,
        ticker,
        companyName: title || '',
        eventType: 'CORPORATE_EVENT',
        rawData: {
          accessionNumber,
          title,
          summary,
          updated,
          rssSource: true,
        },
        detectedAt: new Date(),
      });

      await this.redis.sadd('edgar:processed', accessionNumber);
    }

    this.logger.info(`Ingested ${events.length} events from EDGAR RSS feed`);
    return events;
  }

  private extractXmlTag(xml: string, tag: string): string | null {
    const regex = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`);
    const match = regex.exec(xml);
    return match ? match[1].trim() : null;
  }

  private extractXmlAttr(xml: string, tag: string, attr: string): string | null {
    const regex = new RegExp(`<${tag}[^>]*${attr}="([^"]*)"[^>]*/?>`, 'i');
    const match = regex.exec(xml);
    return match ? match[1] : null;
  }

  private async fetchFiling(accession: string): Promise<EdgarFiling | null> {
    try {
      const url = `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&accession=${accession}&type=&dateb=&owner=include&count=1&output=atom`;
      const response = await fetch(url, {
        headers: { 'User-Agent': process.env.EDGAR_USER_AGENT || 'CorpActionEngine/1.0' },
      });
      if (!response.ok) return null;
      return { accessionNumber: accession } as EdgarFiling;
    } catch {
      return null;
    }
  }
}
