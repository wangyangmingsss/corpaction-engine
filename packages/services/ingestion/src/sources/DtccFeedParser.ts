import { ICorporateActionSource, RawCorporateActionEvent, VerificationResult } from './ICorporateActionSource';
import { Logger } from '../utils/Logger';
import crypto from 'crypto';

// DTCC event type to internal event type mapping
const DTCC_EVENT_TYPE_MAP: Record<string, string> = {
  DVCA: 'DIVIDEND',
  DVOP: 'DIVIDEND',
  SPLF: 'SPLIT',
  SPLR: 'SPLIT',
  MRGR: 'MERGER_REGISTRATION',
  TEND: 'TENDER_OFFER',
  BRUP: 'SPINOFF',
  DLST: 'DELISTING',
  LIQU: 'LIQUIDATION',
  CHAN: 'TICKER_CHANGE',
  RHTS: 'RIGHTS_ISSUE',
  EXRI: 'RIGHTS_EXERCISE',
  REDM: 'REDEMPTION',
};

interface Seev031Notification {
  corporateActionGeneralInformation?: {
    corporateActionEventIdentification?: string;
    eventType?: string;
    mandatoryVoluntaryEventType?: string;
    eventProcessingType?: string;
  };
  accountDetails?: {
    accountIdentification?: string;
  };
  corporateActionDetails?: {
    dateDetails?: {
      recordDate?: string;
      exDate?: string;
      effectiveDate?: string;
      paymentDate?: string;
    };
    rateDetails?: {
      additionalQuantityForExistingSecurities?: {
        numerator?: number;
        denominator?: number;
      };
      grossDividendRate?: number;
      netDividendRate?: number;
    };
    securityIdentification?: {
      isin?: string;
      ticker?: string;
      description?: string;
    };
    cashMovementDetails?: {
      amount?: number;
      currency?: string;
    };
  };
}

export class DtccFeedParser implements ICorporateActionSource {
  readonly name = 'DTCC_ISO20022';
  readonly reliability = 98;

  private logger: Logger;
  private feedUrl: string;
  private apiKey: string;
  private processedIds: Set<string> = new Set();

  constructor(logger: Logger, feedUrl?: string, apiKey?: string) {
    this.logger = logger;
    this.feedUrl = feedUrl || process.env.DTCC_FEED_URL || 'https://api.dtcc.com/corpactions/v1/notifications';
    this.apiKey = apiKey || process.env.DTCC_API_KEY || '';
  }

  async poll(): Promise<RawCorporateActionEvent[]> {
    const events: RawCorporateActionEvent[] = [];

    try {
      const notifications = await this.fetchNotifications();

      for (const notification of notifications) {
        const eventId = notification.corporateActionGeneralInformation?.corporateActionEventIdentification;
        if (!eventId || this.processedIds.has(eventId)) continue;

        const event = this.parseNotification(notification);
        if (event) {
          events.push(event);
          this.processedIds.add(eventId);
        }
      }

      this.logger.info('DTCC feed poll complete', { count: events.length });
    } catch (error) {
      this.logger.error('DTCC feed poll failed', { error: String(error) });
    }

    return events;
  }

  async verify(eventId: string): Promise<VerificationResult> {
    const dtccEventId = eventId.replace('DTCC:', '');
    try {
      const response = await fetch(`${this.feedUrl}/${dtccEventId}`, {
        headers: {
          'Authorization': `Bearer ${this.apiKey}`,
          'Accept': 'application/json',
        },
      });

      if (!response.ok) {
        return { verified: false, details: `DTCC verification failed: HTTP ${response.status}` };
      }

      return { verified: true, details: `DTCC event ${dtccEventId} verified` };
    } catch (error) {
      return { verified: false, details: `DTCC verification error: ${String(error)}` };
    }
  }

  private async fetchNotifications(): Promise<Seev031Notification[]> {
    const response = await fetch(this.feedUrl, {
      headers: {
        'Authorization': `Bearer ${this.apiKey}`,
        'Accept': 'application/json',
        'X-DTCC-Format': 'ISO20022-seev.031',
      },
    });

    if (!response.ok) {
      throw new Error(`DTCC API error: ${response.status} ${response.statusText}`);
    }

    const data = await response.json() as { notifications?: Seev031Notification[] };
    return data.notifications || [];
  }

  private parseNotification(notification: Seev031Notification): RawCorporateActionEvent | null {
    const general = notification.corporateActionGeneralInformation;
    const details = notification.corporateActionDetails;
    const security = details?.securityIdentification;

    if (!general?.corporateActionEventIdentification) {
      this.logger.warn('DTCC notification missing event ID, skipping');
      return null;
    }

    const dtccEventType = general.eventType || '';
    const internalEventType = DTCC_EVENT_TYPE_MAP[dtccEventType];

    if (!internalEventType) {
      this.logger.warn('Unknown DTCC event type', { eventType: dtccEventType });
    }

    const ticker = security?.ticker || '';
    const isin = security?.isin;

    if (!ticker && !isin) {
      this.logger.warn('DTCC notification missing both ticker and ISIN', {
        eventId: general.corporateActionEventIdentification,
      });
      return null;
    }

    const rawData: Record<string, unknown> = {
      dtccEventType,
      mandatoryVoluntary: general.mandatoryVoluntaryEventType,
      eventProcessingType: general.eventProcessingType,
      record_date: details?.dateDetails?.recordDate,
      ex_date: details?.dateDetails?.exDate,
      effective_date: details?.dateDetails?.effectiveDate,
      payment_date: details?.dateDetails?.paymentDate,
    };

    // Map rate/amount details based on event type
    if (details?.rateDetails?.grossDividendRate != null) {
      rawData.dividend = details.rateDetails.grossDividendRate;
      rawData.cash_amount = details.rateDetails.netDividendRate ?? details.rateDetails.grossDividendRate;
    }

    if (details?.rateDetails?.additionalQuantityForExistingSecurities) {
      const ratio = details.rateDetails.additionalQuantityForExistingSecurities;
      rawData.ratio = `${ratio.numerator}:${ratio.denominator}`;
      rawData.numerator = ratio.numerator;
      rawData.denominator = ratio.denominator;
    }

    if (details?.cashMovementDetails) {
      rawData.cash_per_share = details.cashMovementDetails.amount;
      rawData.currency = details.cashMovementDetails.currency;
    }

    const contentHash = crypto.createHash('sha256')
      .update(JSON.stringify(notification))
      .digest('hex');

    return {
      sourceType: this.name,
      sourceId: `DTCC:${general.corporateActionEventIdentification}`,
      contentHash,
      ticker,
      isin,
      companyName: security?.description,
      eventType: internalEventType,
      rawData,
      detectedAt: new Date(),
    };
  }
}
