import { RawCorporateActionEvent } from '../sources/ICorporateActionSource';
import { Logger } from '../utils/Logger';

export interface DeduplicationResult {
  unique: RawCorporateActionEvent[];
  duplicates: RawCorporateActionEvent[];
  conflicts: Array<{
    events: RawCorporateActionEvent[];
    reason: string;
  }>;
}

export class EventDeduplicator {
  private logger: Logger;
  private seen: Map<string, RawCorporateActionEvent> = new Map();

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
      } else if (existing.contentHash === event.contentHash) {
        duplicates.push(event);
        this.logger.debug('Duplicate event detected', {
          key,
          source: event.sourceType,
        });
      } else {
        conflicts.push({
          events: [existing, event],
          reason: `Content hash mismatch: ${existing.sourceType} vs ${event.sourceType}`,
        });
        this.logger.warn('Conflicting events detected', {
          key,
          sources: [existing.sourceType, event.sourceType],
        });
      }
    }

    return { unique, duplicates, conflicts };
  }

  private computeKey(event: RawCorporateActionEvent): string {
    return `${event.ticker}:${event.eventType || 'UNKNOWN'}:${event.detectedAt.toISOString().split('T')[0]}`;
  }

  reset(): void {
    this.seen.clear();
  }
}
