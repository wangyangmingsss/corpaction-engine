import { Redis } from 'ioredis';
import { Logger } from '../utils/Logger';

export type ErrorType =
  | 'EDGAR_API_DOWN'
  | 'TX_REVERTED'
  | 'VALIDATOR_OFFLINE'
  | 'DATA_CONFLICT'
  | 'DB_CONNECTION_FAILURE';

interface RecoveryAction {
  errorType: ErrorType;
  action: string;
  details: Record<string, unknown>;
  timestamp: Date;
}

export class ErrorRecovery {
  private logger: Logger;
  private redis: Redis;

  // Retry state tracking
  private dbRetryCount = 0;
  private readonly MAX_DB_RETRIES = 10;
  private readonly BASE_DB_BACKOFF_MS = 1000;

  constructor(logger: Logger, redis: Redis) {
    this.logger = logger;
    this.redis = redis;
  }

  /**
   * Central error handler. Routes each error type to the appropriate
   * recovery strategy and returns the action taken.
   */
  async handleError(errorType: ErrorType, context: Record<string, unknown> = {}): Promise<RecoveryAction> {
    this.logger.error(`Error detected: ${errorType}`, context);

    let action: RecoveryAction;

    switch (errorType) {
      case 'EDGAR_API_DOWN':
        action = await this.handleEdgarApiDown(context);
        break;
      case 'TX_REVERTED':
        action = await this.handleTxReverted(context);
        break;
      case 'VALIDATOR_OFFLINE':
        action = await this.handleValidatorOffline(context);
        break;
      case 'DATA_CONFLICT':
        action = await this.handleDataConflict(context);
        break;
      case 'DB_CONNECTION_FAILURE':
        action = await this.handleDbConnectionFailure(context);
        break;
      default:
        action = {
          errorType,
          action: 'UNKNOWN_ERROR_LOGGED',
          details: context,
          timestamp: new Date(),
        };
    }

    // Persist recovery action to Redis for auditing
    try {
      await this.redis.xadd(
        'corpaction:recovery_log', '*',
        'errorType', action.errorType,
        'action', action.action,
        'details', JSON.stringify(action.details),
        'timestamp', action.timestamp.toISOString()
      );
    } catch {
      // Redis itself may be down; log to stdout as last resort
      this.logger.error('Could not persist recovery action to Redis', {
        errorType: action.errorType,
      });
    }

    return action;
  }

  /**
   * EDGAR API down: trigger RSS fallback.
   * Publishes a command to the ingestion service to switch
   * the EdgarMonitor into RSS fallback mode.
   */
  private async handleEdgarApiDown(context: Record<string, unknown>): Promise<RecoveryAction> {
    this.logger.warn('EDGAR API down -- triggering RSS fallback');

    await this.redis.publish('corpaction:commands', JSON.stringify({
      command: 'EDGAR_RSS_FALLBACK',
      timestamp: Date.now(),
    }));

    // Also set a flag so any new EdgarMonitor instances start in RSS mode
    await this.redis.set('edgar:use_rss_fallback', 'true', 'EX', 3600);

    return {
      errorType: 'EDGAR_API_DOWN',
      action: 'RSS_FALLBACK_TRIGGERED',
      details: {
        ...context,
        rssFallbackEnabled: true,
        ttlSeconds: 3600,
      },
      timestamp: new Date(),
    };
  }

  /**
   * Transaction reverted: retry with 2x gas.
   * Doubles the gas limit and retries the transaction once.
   * If the retry also reverts, the intent is moved to the failed queue.
   */
  private async handleTxReverted(context: Record<string, unknown>): Promise<RecoveryAction> {
    const intentId = String(context.intentId || '');
    const originalGas = Number(context.gasLimit || 200_000);
    const retryGas = originalGas * 2;
    const isRetry = !!context.isRetry;

    if (isRetry) {
      // Already retried once -- give up and move to failed queue
      this.logger.error('TX retry also reverted; moving to failed queue', {
        intentId,
      });

      await this.redis.xadd(
        'corpaction:failed_submissions', '*',
        'intentId', intentId,
        'reason', 'TX_REVERTED_AFTER_RETRY',
        'data', JSON.stringify(context)
      );

      return {
        errorType: 'TX_REVERTED',
        action: 'MOVED_TO_FAILED_QUEUE',
        details: { intentId, originalGas, retriedGas: originalGas },
        timestamp: new Date(),
      };
    }

    this.logger.warn('TX reverted -- scheduling retry with 2x gas', {
      intentId,
      originalGas,
      retryGas,
    });

    // Queue for retry with doubled gas
    await this.redis.xadd(
      'corpaction:retry_submissions', '*',
      'intentId', intentId,
      'gasLimit', String(retryGas),
      'isRetry', 'true',
      'data', JSON.stringify(context)
    );

    return {
      errorType: 'TX_REVERTED',
      action: 'RETRY_WITH_2X_GAS',
      details: { intentId, originalGas, retryGas },
      timestamp: new Date(),
    };
  }

  /**
   * Validator offline: adjust quorum notification.
   * Checks the current number of live validators via heartbeats
   * and publishes a quorum adjustment if the count drops.
   */
  private async handleValidatorOffline(context: Record<string, unknown>): Promise<RecoveryAction> {
    const offlineValidator = String(context.validatorAddress || '');

    this.logger.warn('Validator offline detected', { offlineValidator });

    // Scan for all validator heartbeat keys to count live validators
    const heartbeatKeys = await this.scanKeys('validator:heartbeat:*');
    const liveValidators = heartbeatKeys.length;

    this.logger.info('Current validator count', { liveValidators });

    // Publish quorum adjustment notification
    await this.redis.publish('validator:coordination', JSON.stringify({
      type: 'QUORUM_ADJUSTMENT',
      offlineValidator,
      liveValidators,
      timestamp: Date.now(),
    }));

    // Store the offline event
    await this.redis.set(
      `validator:offline:${offlineValidator}`,
      Date.now().toString(),
      'EX', 3600
    );

    return {
      errorType: 'VALIDATOR_OFFLINE',
      action: 'QUORUM_NOTIFICATION_SENT',
      details: {
        offlineValidator,
        liveValidators,
      },
      timestamp: new Date(),
    };
  }

  /**
   * Data conflict: hold the event in PENDING status.
   * Conflicting events are stored in a dedicated stream
   * and require manual or multi-source resolution.
   */
  private async handleDataConflict(context: Record<string, unknown>): Promise<RecoveryAction> {
    const ticker = String(context.ticker || '');
    const reason = String(context.reason || 'Unknown conflict');

    this.logger.warn('Data conflict -- holding in PENDING', {
      ticker,
      reason,
    });

    // Store conflict for manual review
    await this.redis.xadd(
      'corpaction:pending_conflicts', '*',
      'ticker', ticker,
      'reason', reason,
      'status', 'PENDING',
      'data', JSON.stringify(context)
    );

    // Set a flag so the deduplicator knows about this pending conflict
    await this.redis.set(
      `conflict:pending:${ticker}`,
      JSON.stringify({ reason, timestamp: Date.now() }),
      'EX', 86400 // 24h TTL
    );

    return {
      errorType: 'DATA_CONFLICT',
      action: 'HELD_IN_PENDING',
      details: { ticker, reason },
      timestamp: new Date(),
    };
  }

  /**
   * DB connection failure: retry with exponential backoff.
   * Backs off from 1s up to ~17 minutes (2^10 * 1000ms),
   * then gives up and alerts.
   */
  async handleDbConnectionFailure(context: Record<string, unknown>): Promise<RecoveryAction> {
    this.dbRetryCount++;

    if (this.dbRetryCount > this.MAX_DB_RETRIES) {
      this.logger.error('DB connection retries exhausted; alerting', {
        retryCount: this.dbRetryCount,
      });

      // Publish critical alert
      try {
        await this.redis.publish('corpaction:alerts', JSON.stringify({
          type: 'DB_CONNECTION_EXHAUSTED',
          retryCount: this.dbRetryCount,
          timestamp: Date.now(),
        }));
      } catch {
        // Redis may also be down
      }

      return {
        errorType: 'DB_CONNECTION_FAILURE',
        action: 'RETRIES_EXHAUSTED_ALERT_SENT',
        details: { retryCount: this.dbRetryCount },
        timestamp: new Date(),
      };
    }

    const backoffMs = this.BASE_DB_BACKOFF_MS * Math.pow(2, this.dbRetryCount - 1);

    this.logger.warn('DB connection failure -- retrying with exponential backoff', {
      retryCount: this.dbRetryCount,
      backoffMs,
    });

    // Wait for the backoff period
    await new Promise(resolve => setTimeout(resolve, backoffMs));

    return {
      errorType: 'DB_CONNECTION_FAILURE',
      action: 'RETRY_WITH_BACKOFF',
      details: {
        retryCount: this.dbRetryCount,
        backoffMs,
        ...context,
      },
      timestamp: new Date(),
    };
  }

  /**
   * Reset DB retry counter (call after a successful reconnection).
   */
  resetDbRetryCount(): void {
    this.dbRetryCount = 0;
  }

  /**
   * Scan Redis keys matching a pattern without blocking.
   */
  private async scanKeys(pattern: string): Promise<string[]> {
    const keys: string[] = [];
    let cursor = '0';

    do {
      const [nextCursor, batch] = await this.redis.scan(
        cursor, 'MATCH', pattern, 'COUNT', 100
      );
      cursor = nextCursor;
      keys.push(...batch);
    } while (cursor !== '0');

    return keys;
  }
}
