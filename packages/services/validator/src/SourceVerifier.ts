import crypto from 'crypto';

export interface VerificationResult {
  verified: boolean;
  sourceType: string;
  sourceId: string;
  contentHash: string;
  details: string;
}

export class SourceVerifier {
  /**
   * Generic verification dispatcher.
   * Routes to the appropriate source-specific verification method
   * based on actionType, matching the interface ValidatorNode expects:
   *   verify(eventId, actionType, params) => { verified, details }
   */
  async verify(
    eventId: string,
    actionType: number,
    params: string
  ): Promise<{ verified: boolean; details: string }> {
    // ActionType enum: 0=DIVIDEND, 1=FORWARD_SPLIT, 2=REVERSE_SPLIT,
    // 3=MERGER_CASH, 4=MERGER_STOCK, 5=MERGER_HYBRID,
    // 6=SPINOFF, 7=DELISTING, 8=LIQUIDATION, 9=TICKER_CHANGE
    if (actionType < 0 || actionType > 9) {
      return { verified: false, details: `Unknown actionType: ${actionType}` };
    }

    // Determine the source type from the eventId prefix
    const sourceType = this.extractSourceType(eventId);

    switch (sourceType) {
      case 'SEC_EDGAR': {
        const parts = eventId.split(':');
        const accessionCandidate = parts.find(p => /^\d{10}-\d{2}-\d{6}$/.test(p));
        if (!accessionCandidate) {
          return { verified: false, details: 'EDGAR source detected but no valid accession number found in eventId' };
        }
        const result = await this.verifyEdgarFiling(accessionCandidate);
        return { verified: result.verified, details: result.details };
      }

      case 'EOD_HISTORICAL': {
        const result = await this.verifyEodHistorical(eventId, actionType, params);
        return { verified: result.verified, details: result.details };
      }

      case 'POLYGON': {
        const result = await this.verifyPolygon(eventId, actionType, params);
        return { verified: result.verified, details: result.details };
      }

      case 'DTCC': {
        const result = await this.verifyDtcc(eventId, params);
        return { verified: result.verified, details: result.details };
      }

      default:
        return {
          verified: false,
          details: `Unrecognized source type '${sourceType}' extracted from eventId '${eventId}'. Cannot verify against an unknown data source.`,
        };
    }
  }

  /**
   * Extract the source type from an eventId.
   * Conventions:
   *   - Contains an EDGAR accession number (XXXXXXXXXX-XX-XXXXXX) => SEC_EDGAR
   *   - Prefixed with "eod:" => EOD_HISTORICAL
   *   - Prefixed with "polygon:" => POLYGON
   *   - Prefixed with "dtcc:" => DTCC
   */
  private extractSourceType(eventId: string): string {
    const lower = eventId.toLowerCase();
    if (lower.startsWith('eod:')) return 'EOD_HISTORICAL';
    if (lower.startsWith('polygon:')) return 'POLYGON';
    if (lower.startsWith('dtcc:')) return 'DTCC';

    // Check for EDGAR accession number pattern anywhere in the eventId
    const parts = eventId.split(':');
    const hasAccession = parts.some(p => /^\d{10}-\d{2}-\d{6}$/.test(p));
    if (hasAccession) return 'SEC_EDGAR';

    return 'UNKNOWN';
  }

  async verifyEdgarFiling(accessionNumber: string): Promise<VerificationResult> {
    try {
      const url = `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&accession=${accessionNumber}&output=atom`;
      const response = await fetch(url, {
        headers: { 'User-Agent': process.env.EDGAR_USER_AGENT || 'CorpActionEngine/1.0' },
      });

      if (!response.ok) {
        return {
          verified: false,
          sourceType: 'SEC_EDGAR',
          sourceId: accessionNumber,
          contentHash: '',
          details: `HTTP ${response.status}`,
        };
      }

      const text = await response.text();
      const contentHash = crypto.createHash('sha256').update(text).digest('hex');

      return {
        verified: true,
        sourceType: 'SEC_EDGAR',
        sourceId: accessionNumber,
        contentHash,
        details: 'Filing verified against SEC EDGAR',
      };
    } catch (error) {
      return {
        verified: false,
        sourceType: 'SEC_EDGAR',
        sourceId: accessionNumber,
        contentHash: '',
        details: String(error),
      };
    }
  }

  /**
   * Verify an event against the EOD Historical Data API.
   * Expects eventId format: "eod:<TICKER>:<DATE>" where DATE is YYYY-MM-DD.
   * For dividends, checks the /div endpoint; for splits, checks the /splits endpoint.
   */
  async verifyEodHistorical(
    eventId: string,
    actionType: number,
    params: string
  ): Promise<VerificationResult> {
    const apiKey = process.env.EOD_API_KEY;
    if (!apiKey) {
      return {
        verified: false,
        sourceType: 'EOD_HISTORICAL',
        sourceId: eventId,
        contentHash: '',
        details: 'EOD_API_KEY environment variable is not set',
      };
    }

    try {
      const parts = eventId.split(':');
      if (parts.length < 3) {
        return {
          verified: false,
          sourceType: 'EOD_HISTORICAL',
          sourceId: eventId,
          contentHash: '',
          details: `Invalid EOD eventId format: expected 'eod:<TICKER>:<DATE>', got '${eventId}'`,
        };
      }

      const ticker = parts[1];
      const date = parts[2];

      // Dividends use actionType 0, splits use actionType 1 (forward) or 2 (reverse)
      let endpoint: string;
      if (actionType === 0) {
        endpoint = `https://eodhistoricaldata.com/api/div/${ticker}?from=${date}&to=${date}&api_token=${apiKey}&fmt=json`;
      } else if (actionType === 1 || actionType === 2) {
        endpoint = `https://eodhistoricaldata.com/api/splits/${ticker}?from=${date}&to=${date}&api_token=${apiKey}&fmt=json`;
      } else {
        endpoint = `https://eodhistoricaldata.com/api/fundamentals/${ticker}?api_token=${apiKey}&fmt=json`;
      }

      const response = await fetch(endpoint);
      if (!response.ok) {
        return {
          verified: false,
          sourceType: 'EOD_HISTORICAL',
          sourceId: eventId,
          contentHash: '',
          details: `EOD API returned HTTP ${response.status}`,
        };
      }

      const data_response = await response.text();
      const contentHash = this.computeContentHash(data_response);

      // For dividend and split endpoints, the API returns an array; verify it's non-empty
      if (actionType === 0 || actionType === 1 || actionType === 2) {
        const parsed = JSON.parse(data_response);
        if (!Array.isArray(parsed) || parsed.length === 0) {
          return {
            verified: false,
            sourceType: 'EOD_HISTORICAL',
            sourceId: eventId,
            contentHash,
            details: `No matching ${actionType === 0 ? 'dividend' : 'split'} event found in EOD Historical Data for ${ticker} on ${date}`,
          };
        }
      }

      return {
        verified: true,
        sourceType: 'EOD_HISTORICAL',
        sourceId: eventId,
        contentHash,
        details: `Event verified against EOD Historical Data API for ${ticker} on ${date}`,
      };
    } catch (error) {
      return {
        verified: false,
        sourceType: 'EOD_HISTORICAL',
        sourceId: eventId,
        contentHash: '',
        details: String(error),
      };
    }
  }

  /**
   * Verify an event against the Polygon.io API.
   * Expects eventId format: "polygon:<TICKER>:<DATE>" where DATE is YYYY-MM-DD.
   * For dividends, checks /v3/reference/dividends; for splits, checks /v3/reference/stock_splits.
   */
  async verifyPolygon(
    eventId: string,
    actionType: number,
    params: string
  ): Promise<VerificationResult> {
    const apiKey = process.env.POLYGON_API_KEY;
    if (!apiKey) {
      return {
        verified: false,
        sourceType: 'POLYGON',
        sourceId: eventId,
        contentHash: '',
        details: 'POLYGON_API_KEY environment variable is not set',
      };
    }

    try {
      const parts = eventId.split(':');
      if (parts.length < 3) {
        return {
          verified: false,
          sourceType: 'POLYGON',
          sourceId: eventId,
          contentHash: '',
          details: `Invalid Polygon eventId format: expected 'polygon:<TICKER>:<DATE>', got '${eventId}'`,
        };
      }

      const ticker = parts[1];
      const date = parts[2];

      let endpoint: string;
      if (actionType === 0) {
        endpoint = `https://api.polygon.io/v3/reference/dividends?ticker=${ticker}&ex_dividend_date=${date}&apiKey=${apiKey}`;
      } else if (actionType === 1 || actionType === 2) {
        endpoint = `https://api.polygon.io/v3/reference/stock_splits?ticker=${ticker}&execution_date=${date}&apiKey=${apiKey}`;
      } else {
        endpoint = `https://api.polygon.io/v3/reference/tickers/${ticker}?apiKey=${apiKey}`;
      }

      const response = await fetch(endpoint);
      if (!response.ok) {
        return {
          verified: false,
          sourceType: 'POLYGON',
          sourceId: eventId,
          contentHash: '',
          details: `Polygon API returned HTTP ${response.status}`,
        };
      }

      const data_response = await response.text();
      const contentHash = this.computeContentHash(data_response);

      // For dividend and split endpoints, Polygon returns { results: [...] }
      if (actionType === 0 || actionType === 1 || actionType === 2) {
        const parsed = JSON.parse(data_response);
        if (!parsed.results || !Array.isArray(parsed.results) || parsed.results.length === 0) {
          return {
            verified: false,
            sourceType: 'POLYGON',
            sourceId: eventId,
            contentHash,
            details: `No matching ${actionType === 0 ? 'dividend' : 'split'} event found in Polygon for ${ticker} on ${date}`,
          };
        }
      }

      return {
        verified: true,
        sourceType: 'POLYGON',
        sourceId: eventId,
        contentHash,
        details: `Event verified against Polygon.io API for ${ticker} on ${date}`,
      };
    } catch (error) {
      return {
        verified: false,
        sourceType: 'POLYGON',
        sourceId: eventId,
        contentHash: '',
        details: String(error),
      };
    }
  }

  /**
   * Verify a DTCC feed event by content hash comparison.
   * DTCC feeds have deterministic content hashes. The expected hash is embedded
   * in the eventId format: "dtcc:<FEED_ID>:<EXPECTED_HASH>".
   * Verification succeeds if the SHA-256 hash of the provided params matches the expected hash.
   */
  async verifyDtcc(
    eventId: string,
    params: string
  ): Promise<VerificationResult> {
    try {
      const parts = eventId.split(':');
      if (parts.length < 3) {
        return {
          verified: false,
          sourceType: 'DTCC',
          sourceId: eventId,
          contentHash: '',
          details: `Invalid DTCC eventId format: expected 'dtcc:<FEED_ID>:<EXPECTED_HASH>', got '${eventId}'`,
        };
      }

      const feedId = parts[1];
      const expectedHash = parts[2];

      if (!params) {
        return {
          verified: false,
          sourceType: 'DTCC',
          sourceId: eventId,
          contentHash: '',
          details: 'No params provided for DTCC content hash verification',
        };
      }

      const computedHash = this.computeContentHash(params);
      const verified = computedHash === expectedHash;

      return {
        verified,
        sourceType: 'DTCC',
        sourceId: feedId,
        contentHash: computedHash,
        details: verified
          ? `DTCC feed content hash verified: ${computedHash.substring(0, 16)}...`
          : `DTCC content hash mismatch: expected ${expectedHash.substring(0, 16)}..., got ${computedHash.substring(0, 16)}...`,
      };
    } catch (error) {
      return {
        verified: false,
        sourceType: 'DTCC',
        sourceId: eventId,
        contentHash: '',
        details: String(error),
      };
    }
  }

  computeContentHash(data: string | Buffer): string {
    return crypto.createHash('sha256').update(data).digest('hex');
  }
}
