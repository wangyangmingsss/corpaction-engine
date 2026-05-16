export interface RawCorporateActionEvent {
  sourceType: string;
  sourceId: string;
  sourceUrl?: string;
  contentHash: string;
  ticker: string;
  isin?: string;
  companyName?: string;
  eventType?: string;
  rawData: Record<string, unknown>;
  detectedAt: Date;
}

export interface VerificationResult {
  verified: boolean;
  details: string;
}

export interface ICorporateActionSource {
  name: string;
  reliability: number;
  poll(): Promise<RawCorporateActionEvent[]>;
  subscribe?(callback: (event: RawCorporateActionEvent) => void): void;
  verify(eventId: string): Promise<VerificationResult>;
}
