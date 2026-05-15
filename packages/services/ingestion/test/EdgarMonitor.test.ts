import { describe, it } from 'node:test';

describe('EdgarMonitor', () => {
  it('should initialize with SEC EDGAR endpoint', () => {
    // TODO: Instantiate EdgarMonitor and verify default config
  });

  it('should poll EDGAR RSS feed and return new filings', () => {
    // TODO: Mock fetch, verify parsed filings
  });

  it.todo('should skip already-seen filings based on accession number');

  it.todo('should emit events to Redis stream on new filing detection');
});
