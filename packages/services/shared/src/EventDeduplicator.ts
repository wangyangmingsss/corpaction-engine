import { RawCorporateActionEvent } from './CorporateActionTypes';

// Minimal Logger interface so shared package has no dependency on service-specific utils
interface Logger {
  debug(message: string, meta?: Record<string, unknown>): void;
  info(message: string, meta?: Record<string, unknown>): void;
  warn(message: string, meta?: Record<string, unknown>): void;
  error(message: string, meta?: Record<string, unknown>): void;
}

export type ConfidenceLevel = 'LOW' | 'MEDIUM' | 'HIGH' | 'PENDING';

export interface DeduplicationResult {
  unique: RawCorporateActionEvent[];
  duplicates: RawCorporateActionEvent[];
  conflicts: Array<{
    events: RawCorporateActionEvent[];
    reason: string;
  }>;
  confidenceLevels: Map<string, ConfidenceLevel>;
}

export class EventDeduplicator {
  private logger: Logger;
  private seen: Map<string, RawCorporateActionEvent> = new Map();
  private sourceCount: Map<string, Set<string>> = new Map();
  private confidenceLevels: Map<string, ConfidenceLevel> = new Map();

  constructor(logger: Logger) {
    this.logger = logger;
  }

  deduplicate(events: RawCorporateActionEvent[]): DeduplicationResult {
    const unique: RawCorporateActionEvent[] = [];
    const duplicates: RawCorporateActionEvent[] = [];
    const conflicts: Array<{ events: RawCorporateActionEvent[]; reason: string }> = [];

    for (const event of events) {
      const key = this.computeKey(event);
      const existing = this.seen.get(key);

      if (!existing) {
        this.seen.set(key, event);
        unique.push(event);

        // Track source for this key
        const sources = new Set<string>();
        sources.add(event.sourceType);
        this.sourceCount.set(key, sources);

        // Single-source events start as PENDING
        this.confidenceLevels.set(key, 'PENDING');
        this.logger.debug('New event (PENDING confirmation)', {
          key,
          source: event.sourceType,
        });
      } else if (this.isContentMatch(existing, event)) {
        duplicates.push(event);

        // Track additional source
        const sources = this.sourceCount.get(key) || new Set();
        sources.add(event.sourceType);
        this.sourceCount.set(key, sources);

        // Auto-promote confidence to HIGH when multiple sources agree
        if (sources.size >= 2) {
          this.confidenceLevels.set(key, 'HIGH');
          this.logger.info('Confidence promoted to HIGH (multi-source agreement)', {
            key,
            sources: Array.from(sources),
          });
        }

        this.logger.debug('Duplicate event detected', {
          key,
          source: event.sourceType,
        });
      } else {
        // Content mismatch - check critical parameters
        const criticalConflict = this.checkCriticalParameters(existing, event);

        if (criticalConflict) {
          conflicts.push({
            events: [existing, event],
            reason: criticalConflict,
          });
          this.confidenceLevels.set(key, 'LOW');
          this.logger.warn('Critical parameter conflict detected', {
            key,
            sources: [existing.sourceType, event.sourceType],
            conflict: criticalConflict,
          });
        } else {
          // Non-critical differences: treat as supplementary data
          duplicates.push(event);
          const sources = this.sourceCount.get(key) || new Set();
          sources.add(event.sourceType);
          this.sourceCount.set(key, sources);

          if (sources.size >= 2) {
            this.confidenceLevels.set(key, 'HIGH');
          }

          this.logger.debug('Non-critical content difference, merged', {
            key,
            source: event.sourceType,
          });
        }
      }
    }

    return { unique, duplicates, conflicts, confidenceLevels: this.confidenceLevels };
  }

  getConfidence(event: RawCorporateActionEvent): ConfidenceLevel {
    const key = this.computeKey(event);
    return this.confidenceLevels.get(key) || 'PENDING';
  }

  private computeKey(event: RawCorporateActionEvent): string {
    // Primary key: ticker + event type + effectiveDate (per spec 5.4)
    // Fall back to detectedAt only when no effectiveDate is available
    const effectiveDate = event.rawData.effective_date || event.rawData.effectiveDate
      || event.rawData.pay_date || event.rawData.ex_dividend_date;
    const dateStr = effectiveDate
      ? new Date(String(effectiveDate)).toISOString().split('T')[0]
      : event.detectedAt.toISOString().split('T')[0];
    const tickerKey = event.ticker
      ? `${event.ticker}:${event.eventType || 'UNKNOWN'}:${dateStr}`
      : null;

    // ISIN fallback matching: use ISIN when ticker is missing
    const isinKey = event.isin
      ? `ISIN:${event.isin}:${event.eventType || 'UNKNOWN'}:${dateStr}`
      : null;

    // If we have a ticker key, check if an ISIN-based entry already exists
    if (tickerKey && isinKey) {
      // Check both; prefer ticker-based key but register ISIN alias
      if (this.seen.has(isinKey) && !this.seen.has(tickerKey)) {
        // Migrate ISIN-keyed entry to ticker key
        const existing = this.seen.get(isinKey)!;
        this.seen.set(tickerKey, existing);
        const sources = this.sourceCount.get(isinKey);
        if (sources) this.sourceCount.set(tickerKey, sources);
        const conf = this.confidenceLevels.get(isinKey);
        if (conf) this.confidenceLevels.set(tickerKey, conf);
        return tickerKey;
      }
      return tickerKey;
    }

    if (tickerKey) return tickerKey;
    if (isinKey) return isinKey;

    // Last resort
    return `UNKNOWN:${event.eventType || 'UNKNOWN'}:${dateStr}`;
  }

  private isContentMatch(a: RawCorporateActionEvent, b: RawCorporateActionEvent): boolean {
    // Exact hash match is the fast path
    if (a.contentHash === b.contentHash) return true;

    // If hashes differ, check if critical parameters still agree
    const criticalConflict = this.checkCriticalParameters(a, b);
    return criticalConflict === null;
  }

  private checkCriticalParameters(
    a: RawCorporateActionEvent,
    b: RawCorporateActionEvent
  ): string | null {
    const aData = a.rawData;
    const bData = b.rawData;

    // Check split ratio mismatch
    if (aData.ratio && bData.ratio && String(aData.ratio) !== String(bData.ratio)) {
      return `Split ratio mismatch: ${aData.ratio} vs ${bData.ratio}`;
    }
    if (aData.numerator && bData.numerator) {
      if (Number(aData.numerator) !== Number(bData.numerator) ||
          Number(aData.denominator) !== Number(bData.denominator)) {
        return `Split ratio components mismatch: ${aData.numerator}/${aData.denominator} vs ${bData.numerator}/${bData.denominator}`;
      }
    }

    // Check dividend amount mismatch
    const aDividend = aData.dividend || aData.cash_amount || aData.amount;
    const bDividend = bData.dividend || bData.cash_amount || bData.amount;
    if (aDividend != null && bDividend != null) {
      const diff = Math.abs(Number(aDividend) - Number(bDividend));
      if (diff > 0.001) {
        return `Dividend amount mismatch: ${aDividend} vs ${bDividend}`;
      }
    }

    // Check merger terms mismatch
    if (aData.exchange_ratio && bData.exchange_ratio) {
      if (Number(aData.exchange_ratio) !== Number(bData.exchange_ratio)) {
        return `Exchange ratio mismatch: ${aData.exchange_ratio} vs ${bData.exchange_ratio}`;
      }
    }
    if (aData.cash_per_share && bData.cash_per_share) {
      const diff = Math.abs(Number(aData.cash_per_share) - Number(bData.cash_per_share));
      if (diff > 0.001) {
        return `Cash per share mismatch: ${aData.cash_per_share} vs ${bData.cash_per_share}`;
      }
    }

    // No critical conflicts found
    return null;
  }

  reset(): void {
    this.seen.clear();
    this.sourceCount.clear();
    this.confidenceLevels.clear();
  }
}
