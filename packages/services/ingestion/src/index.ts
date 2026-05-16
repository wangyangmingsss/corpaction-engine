import { Redis } from 'ioredis';
import { Logger } from './utils/Logger';
import { startMetricsServer } from './metrics';
import { EdgarMonitor } from './sources/EdgarMonitor';
import { EodHistoricalAdapter } from './sources/EodHistoricalAdapter';
import { PolygonAdapter } from './sources/PolygonAdapter';
import { EventDeduplicator } from './dedup/EventDeduplicator';
import { EventClassifier } from './classifier/EventClassifier';
import { ICorporateActionSource, RawCorporateActionEvent } from './sources/ICorporateActionSource';

const logger = new Logger('ingestion', 'main');

startMetricsServer();

async function main() {
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');

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

  const deduplicator = new EventDeduplicator(new Logger('ingestion', 'Deduplicator'));
  const classifier = new EventClassifier(new Logger('ingestion', 'Classifier'));

  logger.info('Ingestion service starting', { sourceCount: sources.length });

  // Poll all sources
  const allEvents: RawCorporateActionEvent[] = [];
  for (const source of sources) {
    try {
      const events = await source.poll();
      allEvents.push(...events);
      logger.info(`Polled ${events.length} events from ${source.name}`);
    } catch (error) {
      logger.error(`Failed to poll ${source.name}`, { error: String(error) });
    }
  }

  // Deduplicate
  const { unique, duplicates, conflicts } = deduplicator.deduplicate(allEvents);
  logger.info('Deduplication complete', {
    unique: unique.length,
    duplicates: duplicates.length,
    conflicts: conflicts.length,
  });

  // Classify
  for (const event of unique) {
    const classification = classifier.classify(event);
    if (classification) {
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
