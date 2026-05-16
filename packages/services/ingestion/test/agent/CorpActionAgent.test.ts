import { describe, it, expect, vi, beforeEach } from 'vitest';
import { CorpActionAgent } from '../../src/agent/CorpActionAgent';
import { RawCorporateActionEvent } from '../../src/sources/ICorporateActionSource';

// --- Mock Anthropic SDK ---
const mockCreate = vi.fn();
vi.mock('@anthropic-ai/sdk', () => {
  return {
    default: class MockAnthropic {
      messages = { create: mockCreate };
      constructor() {}
    },
  };
});

// --- Mock Redis ---
const mockRedisGet = vi.fn();
const mockRedisSet = vi.fn();
const mockRedisXadd = vi.fn();

const mockRedis = {
  get: mockRedisGet,
  set: mockRedisSet,
  xadd: mockRedisXadd,
} as any;

// --- Mock Logger ---
const mockLogger = {
  info: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
  debug: vi.fn(),
} as any;

// --- Test fixtures ---

function makeEvent(overrides?: Partial<RawCorporateActionEvent>): RawCorporateActionEvent {
  return {
    sourceType: 'EDGAR',
    sourceId: 'filing-123',
    contentHash: 'abc123hash',
    ticker: 'ACME',
    companyName: 'ACME Corp',
    eventType: 'CORPORATE_EVENT',
    rawData: {
      items: ['8.01'],
      description: 'Company announces special distribution to shareholders',
    },
    detectedAt: new Date('2026-01-15T10:00:00Z'),
    ...overrides,
  };
}

function makeAIResponse(actionType: string, confidence: string, reasoning: string) {
  return {
    content: [
      {
        type: 'text' as const,
        text: JSON.stringify({
          actionType,
          confidence,
          reasoning,
          signals: ['ai_detected_signal'],
          params: { extractedParam: 'value' },
        }),
      },
    ],
  };
}

// --- Tests ---

describe('CorpActionAgent', () => {
  let agent: CorpActionAgent;

  beforeEach(() => {
    vi.clearAllMocks();
    mockRedisGet.mockResolvedValue(null);
    mockRedisSet.mockResolvedValue('OK');
    mockRedisXadd.mockResolvedValue('stream-id');

    agent = new CorpActionAgent(mockRedis, mockLogger, {
      apiKey: 'test-key',
      model: 'claude-sonnet-4-20250514',
      maxTokens: 1024,
      maxRetries: 2,
      baseDelayMs: 10, // Fast retries for tests
      cacheTtlSeconds: 3600,
    });
  });

  describe('cache hit', () => {
    it('should return cached result without calling AI API', async () => {
      const cachedResult = {
        actionType: 'DIVIDEND',
        confidence: 'HIGH',
        reasoning: 'Cached classification',
        signals: ['cached_signal'],
        params: { amount: 1.5 },
        modelUsed: 'claude-sonnet-4-20250514',
        latencyMs: 150,
        cached: false,
      };

      mockRedisGet.mockResolvedValue(JSON.stringify(cachedResult));

      const event = makeEvent();
      const result = await agent.classifyAmbiguousEvent(event);

      expect(result).not.toBeNull();
      expect(result!.cached).toBe(true);
      expect(result!.actionType).toBe('DIVIDEND');
      expect(result!.confidence).toBe('HIGH');

      // API should NOT have been called
      expect(mockCreate).not.toHaveBeenCalled();

      // Cache key should have been checked
      expect(mockRedisGet).toHaveBeenCalledWith(
        `ai:classify:EDGAR:filing-123:abc123hash`
      );
    });

    it('should proceed to API if cache read fails', async () => {
      mockRedisGet.mockRejectedValue(new Error('Redis connection error'));
      mockCreate.mockResolvedValue(makeAIResponse('SPINOFF', 'MEDIUM', 'Detected spinoff language'));

      const event = makeEvent();
      const result = await agent.classifyAmbiguousEvent(event);

      expect(result).not.toBeNull();
      expect(result!.actionType).toBe('SPINOFF');
      expect(result!.cached).toBe(false);
      expect(mockCreate).toHaveBeenCalledTimes(1);
    });
  });

  describe('ambiguous 8-K classification', () => {
    it('should classify ambiguous 8-K filing via AI', async () => {
      mockCreate.mockResolvedValue(
        makeAIResponse('LIQUIDATION', 'MEDIUM', 'Item 8.01 with distribution language suggests liquidation')
      );

      const event = makeEvent({
        eventType: 'CORPORATE_EVENT',
        rawData: {
          items: ['8.01'],
          description: 'Company announces plan of dissolution and distribution of assets',
          filing_type: '8-K',
        },
      });

      const result = await agent.classifyAmbiguousEvent(event);

      expect(result).not.toBeNull();
      expect(result!.actionType).toBe('LIQUIDATION');
      expect(result!.confidence).toBe('MEDIUM');
      expect(result!.reasoning).toContain('liquidation');
      expect(result!.cached).toBe(false);
      expect(result!.modelUsed).toBe('claude-sonnet-4-20250514');
      expect(result!.latencyMs).toBeGreaterThanOrEqual(0);

      // Should have been called exactly once (no retries needed)
      expect(mockCreate).toHaveBeenCalledTimes(1);

      // Should have written to cache
      expect(mockRedisSet).toHaveBeenCalledTimes(1);
      expect(mockRedisSet).toHaveBeenCalledWith(
        expect.stringContaining('ai:classify:'),
        expect.any(String),
        'EX',
        3600
      );

      // Should have published metrics to stream
      expect(mockRedisXadd).toHaveBeenCalledTimes(1);
    });

    it('should retry on first failure and succeed on second attempt', async () => {
      mockCreate
        .mockRejectedValueOnce(new Error('API rate limited'))
        .mockResolvedValueOnce(makeAIResponse('MERGER_CASH', 'HIGH', 'Clear merger with cash consideration'));

      const event = makeEvent({
        eventType: 'CORPORATE_EVENT',
        rawData: {
          items: ['1.01'],
          description: 'Definitive merger agreement for $50 per share',
          cash_per_share: 50,
        },
      });

      const result = await agent.classifyAmbiguousEvent(event);

      expect(result).not.toBeNull();
      expect(result!.actionType).toBe('MERGER_CASH');
      expect(mockCreate).toHaveBeenCalledTimes(2);
    });
  });

  describe('API failure graceful degradation', () => {
    it('should return null after all retries are exhausted', async () => {
      mockCreate.mockRejectedValue(new Error('Service unavailable'));

      const event = makeEvent();
      const result = await agent.classifyAmbiguousEvent(event);

      expect(result).toBeNull();

      // Should have retried maxRetries times (2)
      expect(mockCreate).toHaveBeenCalledTimes(2);

      // Should have logged error
      expect(mockLogger.error).toHaveBeenCalledWith(
        expect.stringContaining('AI classification failed after all retries'),
        expect.objectContaining({ ticker: 'ACME' })
      );
    });

    it('should return null if API returns no text content', async () => {
      mockCreate.mockResolvedValue({ content: [] });

      const event = makeEvent();
      const result = await agent.classifyAmbiguousEvent(event);

      // After retries fail due to "No text content" error, returns null
      expect(result).toBeNull();
    });

    it('should return null if API returns invalid JSON', async () => {
      mockCreate.mockResolvedValue({
        content: [{ type: 'text', text: 'This is not JSON' }],
      });

      const event = makeEvent();
      const result = await agent.classifyAmbiguousEvent(event);

      expect(result).toBeNull();
    });
  });
});
