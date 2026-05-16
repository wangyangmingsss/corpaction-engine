import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert';
import { EdgarMonitor } from '../src/sources/EdgarMonitor';

// Minimal Redis stub
function createRedisStub() {
  const members = new Set<string>();
  return {
    sismember: async (_key: string, val: string) => (members.has(val) ? 1 : 0),
    sadd: async (_key: string, val: string) => { members.add(val); return 1; },
    xadd: async (..._args: unknown[]) => 'stream-id',
    set: async (..._args: unknown[]) => 'OK',
  };
}

// Minimal Logger stub
function createLoggerStub() {
  return {
    info: (..._a: unknown[]) => {},
    warn: (..._a: unknown[]) => {},
    error: (..._a: unknown[]) => {},
    debug: (..._a: unknown[]) => {},
    setTraceId: () => {},
  };
}

describe('EdgarMonitor', () => {
  let monitor: EdgarMonitor;

  beforeEach(() => {
    monitor = new EdgarMonitor(createRedisStub() as any, createLoggerStub() as any);
  });

  it('should create an instance with correct name and reliability', () => {
    assert.strictEqual(monitor.name, 'SEC_EDGAR');
    assert.strictEqual(monitor.reliability, 95);
  });

  it('isMarketHours returns a boolean', () => {
    // isMarketHours is private, so we access it via bracket notation for testing
    const result = (monitor as any).isMarketHours();
    assert.strictEqual(typeof result, 'boolean');
  });

  it('classifyForm maps known forms correctly', () => {
    const classify = (monitor as any).classifyForm.bind(monitor);
    assert.strictEqual(classify('8-K'), 'CORPORATE_EVENT');
    assert.strictEqual(classify('14A'), 'PROXY_VOTE');
    assert.strictEqual(classify('S-4'), 'MERGER_REGISTRATION');
    assert.strictEqual(classify('SC TO-T'), 'TENDER_OFFER');
    assert.strictEqual(classify('25-NSE'), 'DELISTING');
    assert.strictEqual(classify('10-Q'), undefined);
  });

  it('poll handles network errors gracefully and returns empty array', async () => {
    // Replace the private fetchRecentFilings to simulate a network error
    const originalFetch = (monitor as any).fetchRecentFilings;
    (monitor as any).fetchRecentFilings = async () => {
      throw new Error('Network timeout');
    };
    // Also stub pollRssFeed so fallback also fails gracefully
    (monitor as any).pollRssFeed = async () => {
      throw new Error('RSS also down');
    };

    const events = await monitor.poll();
    assert.ok(Array.isArray(events));
    // After MAX_CONSECUTIVE_FAILURES (3), it switches to RSS fallback.
    // Since we fail all 5 forms but break after 3, we still get an array.
    assert.strictEqual(events.length, 0);

    // Restore
    (monitor as any).fetchRecentFilings = originalFetch;
  });

  it('poll returns parsed events for successful filings', async () => {
    const fakeFiling = {
      accessionNumber: '0001234567-24-000001',
      filingDate: '2024-01-15',
      form: '8-K',
      fileUrl: 'https://www.sec.gov/Archives/edgar/data/123/0001234567-24-000001',
      companyName: 'Test Corp',
      cik: '123',
      ticker: 'TEST',
    };

    // Stub fetchRecentFilings to return one filing for the first form, empty for rest
    let callCount = 0;
    (monitor as any).fetchRecentFilings = async (form: string) => {
      callCount++;
      if (callCount === 1) return [fakeFiling];
      return [];
    };

    const events = await monitor.poll();
    assert.ok(events.length >= 1);
    assert.strictEqual(events[0].sourceType, 'SEC_EDGAR');
    assert.ok(events[0].sourceId.includes('0001234567-24-000001'));
    assert.strictEqual(events[0].ticker, 'TEST');
    assert.strictEqual(events[0].eventType, 'CORPORATE_EVENT');
    assert.ok(events[0].contentHash.length > 0);
  });

  it('poll skips already-processed filings via Redis', async () => {
    const fakeFiling = {
      accessionNumber: '0001234567-24-000099',
      filingDate: '2024-01-15',
      form: '8-K',
      fileUrl: 'https://example.com',
      companyName: 'Dup Corp',
      cik: '999',
      ticker: 'DUP',
    };

    // Pre-populate Redis with the accession number
    const redis = createRedisStub();
    await redis.sadd('edgar:processed', '0001234567-24-000099');
    const mon = new EdgarMonitor(redis as any, createLoggerStub() as any);

    (mon as any).fetchRecentFilings = async () => [fakeFiling];

    const events = await mon.poll();
    assert.strictEqual(events.length, 0);
  });
});
