import { ethers } from 'ethers';
import { Redis } from 'ioredis';
import { Pool } from 'pg';
import { Logger } from './utils/Logger';
import { registry, startMetricsServer } from './metrics';
import { EventDeduplicator } from './dedup/EventDeduplicator';
import { EventClassifier } from './classifier/EventClassifier';
import { ActionIntentBuilder, ClassifiedEvent } from './builder/ActionIntentBuilder';
import { MerkleTreeBuilder } from './builder/MerkleTreeBuilder';
import { OnChainSubmitter } from './submitter/OnChainSubmitter';
import { ErrorRecovery } from './recovery/ErrorRecovery';
import { RawCorporateActionEvent } from './types/CorporateActionTypes';

const logger = new Logger('processor', 'main');

startMetricsServer();

async function main() {
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');
  const rpcUrl = process.env.RPC_URL || 'http://localhost:8545';
  const privateKey = process.env.PROCESSOR_PRIVATE_KEY || '';
  const registryAddress = process.env.REGISTRY_ADDRESS || '';

  // PostgreSQL connection pool
  const pgPool = new Pool({
    connectionString: process.env.DATABASE_URL || 'postgres://corpaction:corpaction_dev@localhost:5432/corpaction',
  });

  // Error recovery handler
  const errorRecovery = new ErrorRecovery(logger, redis);

  // Merkle tree builder for DIVIDEND and SPINOFF distributions
  const merkleTreeBuilder = new MerkleTreeBuilder();

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

        registry.gauge('corpaction_processor_events_pending', 'Pending events in queue', rawEvents.length);

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
          registry.counter('corpaction_intents_built_total', 'Intents built', { action_type: intent.actionType });

          // Stage 3b: Build Merkle tree for DIVIDEND and SPINOFF actions
          if (classification.actionType === 'DIVIDEND' || classification.actionType === 'SPINOFF') {
            try {
              const holders = (classification.params.holders as Array<{ address: string; amount: string }>) || [];
              if (holders.length > 0) {
                const holderEntries = holders.map(h => ({
                  address: h.address,
                  amount: BigInt(h.amount),
                }));
                const merkleStart = Date.now();
                const treeData = merkleTreeBuilder.buildTree(holderEntries);
                const merkleElapsed = Date.now() - merkleStart;
                registry.histogram('corpaction_merkle_tree_build_seconds', 'Merkle tree build time', merkleElapsed / 1000);
                logger.info('Merkle tree built', {
                  intentId: intent.intentId,
                  root: treeData.root,
                  totalHolders: treeData.totalHolders,
                });

                // Persist Merkle tree to PostgreSQL
                try {
                  await pgPool.query(
                    `INSERT INTO merkle_trees (intent_id, merkle_root, snapshot_block, total_holders, total_amount, tree_data)
                     VALUES ($1, $2, $3, $4, $5, $6)
                     ON CONFLICT (intent_id) DO NOTHING`,
                    [
                      Buffer.from(intent.intentId.slice(2), 'hex'),
                      Buffer.from(treeData.root.slice(2), 'hex'),
                      Number(classification.params.snapshotBlock || classification.params.snapshot_block || 0),
                      treeData.totalHolders,
                      treeData.totalAmount,
                      JSON.stringify(treeData),
                    ]
                  );
                  errorRecovery.resetDbRetryCount();
                } catch (dbErr) {
                  await errorRecovery.handleError('DB_CONNECTION_FAILURE', {
                    operation: 'insert_merkle_tree',
                    intentId: intent.intentId,
                    error: String(dbErr),
                  });
                }
              }
            } catch (merkleErr) {
              logger.error('Merkle tree build failed', {
                intentId: intent.intentId,
                error: String(merkleErr),
              });
            }
          }

          // Persist corporate action to PostgreSQL
          try {
            const dates = {
              effectiveDate: intent.effectiveDate ? new Date(intent.effectiveDate * 1000) : new Date(),
              recordDate: intent.recordDate ? new Date(intent.recordDate * 1000) : null,
              exDate: intent.exDate ? new Date(intent.exDate * 1000) : null,
            };
            await pgPool.query(
              `INSERT INTO corporate_actions
                (action_type, ticker, isin, effective_date, record_date, ex_date, params, confidence, intent_id, on_chain_status)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'PENDING')
               ON CONFLICT (ticker, action_type, effective_date) DO UPDATE SET
                 params = EXCLUDED.params,
                 confidence = EXCLUDED.confidence,
                 intent_id = EXCLUDED.intent_id,
                 updated_at = NOW()`,
              [
                classification.actionType,
                event.ticker,
                event.isin || null,
                dates.effectiveDate,
                dates.recordDate,
                dates.exDate,
                JSON.stringify(classification.params),
                classification.confidence,
                Buffer.from(intent.intentId.slice(2), 'hex'),
              ]
            );
            errorRecovery.resetDbRetryCount();
          } catch (dbErr) {
            await errorRecovery.handleError('DB_CONNECTION_FAILURE', {
              operation: 'insert_corporate_action',
              intentId: intent.intentId,
              error: String(dbErr),
            });
          }

          // Stage 4: Submit on-chain
          if (submitter) {
            try {
              const txHash = await submitter.submitIntent(intent);
              registry.counter('corpaction_chain_submissions_total', 'On-chain submissions');
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
              registry.counter('corpaction_chain_submission_errors_total', 'Submission errors');
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

              // Use ErrorRecovery for TX_REVERTED handling
              await errorRecovery.handleError('TX_REVERTED', {
                intentId: intent.intentId,
                error: String(submitError),
              });
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

        // Log and store conflicts via ErrorRecovery
        for (const conflict of dedupResult.conflicts) {
          logger.warn('Data conflict detected, holding events', {
            reason: conflict.reason,
            tickers: conflict.events.map(e => e.ticker),
          });
          await redis.xadd(
            'corpaction:conflicts', '*',
            'data', JSON.stringify(conflict)
          );
          await errorRecovery.handleError('DATA_CONFLICT', {
            reason: conflict.reason,
            ticker: conflict.events[0]?.ticker || 'unknown',
            eventCount: conflict.events.length,
          });
        }
      }
    } catch (error) {
      logger.error('Processing error', { error: String(error) });
      const errorStr = String(error).toLowerCase();
      if (errorStr.includes('connect') || errorStr.includes('econnrefused') || errorStr.includes('pg') || errorStr.includes('database')) {
        await errorRecovery.handleError('DB_CONNECTION_FAILURE', { error: String(error) });
      } else {
        await new Promise(r => setTimeout(r, 5000));
      }
    }
  }
}

main().catch((error) => {
  logger.error('Fatal error', { error: String(error) });
  process.exit(1);
});
