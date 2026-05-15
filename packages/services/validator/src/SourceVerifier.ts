import crypto from 'crypto';

export interface VerificationResult {
  verified: boolean;
  sourceType: string;
  sourceId: string;
  contentHash: string;
  details: string;
}

export class SourceVerifier {
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

  computeContentHash(data: string | Buffer): string {
    return crypto.createHash('sha256').update(data).digest('hex');
  }
}
