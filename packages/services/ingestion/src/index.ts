import { Redis } from 'ioredis';
import { Pool } from 'pg';
import { Logger } from './utils/Logger';
import { registry, startMetricsServer } from './metrics';
import { EdgarMonitor } from './sources/EdgarMonitor';
import { EodHistoricalAdapter } from './sources/EodHistoricalAdapter';
import { PolygonAdapter } from './sources/PolygonAdapter';
import { EventDeduplicator } from './dedup/EventDeduplicator';
import { HybridClassifier } from './classifier/HybridClassifier';
import { AlphaVantageAdapter } from './sources/AlphaVantageAdapter';
import { ICorporateActionSource, RawCorporateActionEvent } from './sources/ICorporateActionSource';

const logger = new Logger('ingestion', 'main');

startMetricsServer();

async function main() {
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');

  // PostgreSQL connection pool
  const pgPool = new Pool({
    connectionString: process.env.DATABASE_URL || 'postgres://corpaction:corpaction_dev@localhost:5432/corpaction',
  });

  const sources: ICorporateActionSource[] = [
    new EdgarMonitor(redis, new Logger('ingestion', 'EdgarMonitor')),
    new EodHistoricalAdapter(
      process.env.EOD_API_KEY || '',
      new Logger('ingestion', 'EodHistorical')
    ),
    new PolygonAdapter(
      process.env.POLYGON_API_KEY || '',
      new Logger('ingestion', 'Polygon')
    ),
  ];

  // Conditionally add AlphaVantage if API key is configured
  if (process.env.ALPHA_VANTAGE_API_KEY) {
    const watchlist = (process.env.ALPHA_VANTAGE_WATCHLIST || '').split(',').filter(Boolean);
    sources.push(
      new AlphaVantageAdapter(
        new Logger('ingestion', 'AlphaVantage'),
        process.env.ALPHA_VANTAGE_API_KEY,
        watchlist
      )
    );
  }

  const deduplicator = new EventDeduplicator(new Logger('ingestion', 'Deduplicator'));
  const classifier = new HybridClassifier(redis, new Logger('ingestion', 'HybridClassifier'));

  logger.info('Ingestion service starting', { sourceCount: sources.length });
  logger.info('AI agent status', { enabled: !!process.env.ANTHROPIC_API_KEY });

  // Poll all sources
  const allEvents: RawCorporateActionEvent[] = [];
  for (const source of sources) {
    try {
      const pollStart = Date.now();
      const events = await source.poll();
      const pollElapsed = (Date.now() - pollStart) / 1000;
      registry.histogram('corpaction_source_poll_latency_seconds', 'Source poll latency', pollElapsed, { source: source.name });
      allEvents.push(...events);
      registry.counter('corpaction_events_ingested_total', 'Total events ingested', { source: source.name });
      logger.info(`Polled ${events.length} events from ${source.name}`);

      // Persist raw events to PostgreSQL
      for (const event of events) {
        try {
          await pgPool.query(
            `INSERT INTO raw_events (source, source_id, source_url, content_hash, raw_data, ticker, isin, status)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'INGESTED')
             ON CONFLICT (source, source_id) DO NOTHING`,
            [
              event.sourceType,
              event.sourceId,
              event.sourceUrl || null,
              Buffer.from(event.contentHash || '', 'utf-8'),
              JSON.stringify(event),
              event.ticker || null,
              event.isin || null,
            ]
          );
        } catch (dbErr) {
          logger.error('Failed to persist raw event to PostgreSQL', {
            sourceId: event.sourceId,
            error: String(dbErr),
          });
        }
      }
    } catch (error) {
      logger.error(`Failed to poll ${source.name}`, { error: String(error) });
      registry.counter('corpaction_ingestion_errors_total', 'Ingestion errors', { source: source.name });
    }
  }

  // Deduplicate
  const { unique, duplicates, conflicts } = deduplicator.deduplicate(allEvents);
  registry.gauge('corpaction_events_deduplicated', 'Deduplicated event counts', unique.length, { type: 'unique' });
  logger.info('Deduplication complete', {
    unique: unique.length,
    duplicates: duplicates.length,
    conflicts: conflicts.length,
  });

  // Classify
  for (const event of unique) {
    const classification = await classifier.classify(event);
    if (classification) {
      registry.counter('corpaction_events_classified_total', 'Events classified', { action_type: classification.actionType });
      await redis.xadd(
        'corpaction:classified_events', '*',
        'source', event.sourceType,
        'ticker', event.ticker,
        'actionType', classification.actionType,
        'confidence', classification.confidence,
        'data', JSON.stringify({ event, classification })
      );
      logger.info('Event classified', {
        ticker: event.ticker,
        actionType: classification.actionType,
        confidence: classification.confidence,
      });
    }
  }

  // Start EDGAR continuous monitoring
  const edgarMonitor = sources[0] as EdgarMonitor;
  await edgarMonitor.start();
}

main().catch((error) => {
  logger.error('Fatal error', { error: String(error) });
  process.exit(1);
});
