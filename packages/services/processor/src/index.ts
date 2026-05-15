import { ethers } from 'ethers';
import { Redis } from 'ioredis';
import { Logger } from './utils/Logger';
import { EventDeduplicator } from '../../ingestion/src/dedup/EventDeduplicator';
import { EventClassifier } from '../../ingestion/src/classifier/EventClassifier';
import { ActionIntentBuilder, ClassifiedEvent } from './builder/ActionIntentBuilder';
import { OnChainSubmitter } from './submitter/OnChainSubmitter';
import { RawCorporateActionEvent } from '../../ingestion/src/sources/ICorporateActionSource';

const logger = new Logger('processor', 'main');

async function main() {
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');
  const rpcUrl = process.env.RPC_URL || 'http://localhost:8545';
  const privateKey = process.env.PROCESSOR_PRIVATE_KEY || '';
  const registryAddress = process.env.REGISTRY_ADDRESS || '';

  // Pipeline components
  const deduplicator = new EventDeduplicator(logger);
  const classifier = new EventClassifier(logger);

  // Load token registry from Redis
  const tokenRegistry = new Map<string, string>();
  const tokens = await redis.hgetall('corpaction:token_registry');
  for (const [ticker, address] of Object.entries(tokens)) {
    tokenRegistry.set(ticker, address);
  }
  const intentBuilder = new ActionIntentBuilder(tokenRegistry);

  // On-chain submitter (initialised only when credentials are available)
  const submitter = (privateKey && registryAddress)
    ? new OnChainSubmitter(rpcUrl, privateKey, registryAddress)
    : null;

  logger.info('Processor service starting', {
    registryAddress,
    tokenCount: tokenRegistry.size,
    submitterEnabled: !!submitter,
  });

  // Listen for raw events from Redis stream
  let lastId = '0';

  while (true) {
    try {
      const results = await redis.xread(
        'BLOCK', 5000,
        'COUNT', 10,
        'STREAMS', 'corpaction:raw_events', lastId
      );

      if (!results) continue;

      for (const [, messages] of results) {
        // Collect raw events from this batch
        const rawEvents: RawCorporateActionEvent[] = [];

        for (const [id, fields] of messages) {
          lastId = id;
          const dataIdx = fields.indexOf('data');
          if (dataIdx === -1) continue;
          const raw = JSON.parse(fields[dataIdx + 1]);
          raw.detectedAt = new Date(raw.detectedAt);
          rawEvents.push(raw);
        }

        if (rawEvents.length === 0) continue;

        // --- Pipeline Stage 1: Dedup ---
        const dedupResult = deduplicator.deduplicate(rawEvents);
        logger.info('Deduplication complete', {
          unique: dedupResult.unique.length,
          duplicates: dedupResult.duplicates.length,
          conflicts: dedupResult.conflicts.length,
        });

        // --- Pipeline Stage 2 + 3 + 4: Classify -> Build Intent -> Submit ---
        for (const event of dedupResult.unique) {
          const confidence = deduplicator.getConfidence(event);

          // Hold single-source events in PENDING until confirmed
          if (confidence === 'PENDING') {
            logger.info('Event held in PENDING (awaiting multi-source confirmation)', {
              ticker: event.ticker,
              eventType: event.eventType,
            });
            await redis.xadd(
              'corpaction:pending_events', '*',
              'data', JSON.stringify(event)
            );
            continue;
          }

          // Stage 2: Classify
          const classification = classifier.classify(event);
          if (!classification) {
            logger.warn('Event could not be classified, skipping', {
              ticker: event.ticker,
              eventType: event.eventType,
            });
            continue;
          }

          logger.info('Event classified', {
            ticker: event.ticker,
            actionType: classification.actionType,
            confidence: classification.confidence,
          });

          // Stage 3: Build Intent
          const classifiedEvent: ClassifiedEvent = {
            ticker: event.ticker,
            isin: event.isin,
            actionType: classification.actionType,
            confidence: classification.confidence,
            params: classification.params,
            sourceType: event.sourceType,
            sourceId: event.sourceId,
            contentHash: event.contentHash,
          };

          const intent = intentBuilder.build(classifiedEvent);
          if (!intent) {
            logger.warn('Could not build intent (token not in registry?)', {
              ticker: event.ticker,
            });
            await redis.xadd(
              'corpaction:classified_events', '*',
              'data', JSON.stringify({ event, classification })
            );
            continue;
          }

          logger.info('Intent built', {
            intentId: intent.intentId,
            actionType: intent.actionType,
            targetToken: intent.targetToken,
          });

          // Stage 4: Submit on-chain
          if (submitter) {
            try {
              const txHash = await submitter.submitIntent(intent);
              logger.info('Intent submitted on-chain', {
                intentId: intent.intentId,
                txHash,
              });

              await redis.xadd(
                'corpaction:submitted_intents', '*',
                'intentId', intent.intentId,
                'txHash', txHash,
                'data', JSON.stringify(intent)
              );
            } catch (submitError) {
              logger.error('On-chain submission failed', {
                intentId: intent.intentId,
                error: String(submitError),
              });

              await redis.xadd(
                'corpaction:failed_submissions', '*',
                'intentId', intent.intentId,
                'data', JSON.stringify(intent),
                'error', String(submitError)
              );
            }
          } else {
            logger.warn('No submitter configured; publishing to classified_events only', {
              intentId: intent.intentId,
            });
            await redis.xadd(
              'corpaction:classified_events', '*',
              'data', JSON.stringify({ event, classification, intent })
            );
          }
        }

        // Log and store conflicts
        for (const conflict of dedupResult.conflicts) {
          logger.warn('Data conflict detected, holding events', {
            reason: conflict.reason,
            tickers: conflict.events.map(e => e.ticker),
          });
          await redis.xadd(
            'corpaction:conflicts', '*',
            'data', JSON.stringify(conflict)
          );
        }
      }
    } catch (error) {
      logger.error('Processing error', { error: String(error) });
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

main().catch((error) => {
  logger.error('Fatal error', { error: String(error) });
  process.exit(1);
});
