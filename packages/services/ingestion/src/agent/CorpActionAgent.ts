import Anthropic from '@anthropic-ai/sdk';
import { Redis } from 'ioredis';
import { Logger } from '../utils/Logger';
import { registry } from '../metrics';
import { ActionType, ConfidenceLevel } from '../classifier/EventClassifier';
import { RawCorporateActionEvent } from '../sources/ICorporateActionSource';

// --- Interfaces ---

export interface AgentClassificationResult {
  actionType: ActionType;
  confidence: ConfidenceLevel;
  reasoning: string;
  signals: string[];
  params: Record<string, unknown>;
  modelUsed: string;
  latencyMs: number;
  cached: boolean;
}

export interface AgentConfig {
  apiKey: string;
  model: string;
  maxTokens: number;
  maxRetries: number;
  baseDelayMs: number;
  cacheTtlSeconds: number;
}

// --- System Prompt ---

const CLASSIFICATION_SYSTEM_PROMPT = `You are a corporate actions classification expert for financial markets.
Your job is to analyze SEC filings, press releases, and market data to classify corporate action events.

You MUST respond with valid JSON matching this schema:
{
  "actionType": one of ["DIVIDEND", "FORWARD_SPLIT", "REVERSE_SPLIT", "MERGER_CASH", "MERGER_STOCK", "MERGER_HYBRID", "SPINOFF", "DELISTING", "LIQUIDATION", "TICKER_CHANGE"],
  "confidence": one of ["LOW", "MEDIUM", "HIGH"],
  "reasoning": "Brief explanation of why this classification was chosen",
  "signals": ["list", "of", "evidence", "signals"],
  "params": { extracted parameters relevant to the action type }
}

Classification rules:
- DIVIDEND: Cash or stock distributions to shareholders. Look for ex-date, pay date, record date, amount.
- FORWARD_SPLIT: Stock split where shares increase (e.g., 2:1, 3:1). Numerator > denominator.
- REVERSE_SPLIT: Stock split where shares decrease (e.g., 1:10, 1:5). Numerator < denominator.
- MERGER_CASH: Acquisition where shareholders receive cash consideration only.
- MERGER_STOCK: Acquisition where shareholders receive stock of acquiring company only.
- MERGER_HYBRID: Acquisition with both cash and stock consideration.
- SPINOFF: Separation of a division/subsidiary into an independent company.
- DELISTING: Removal of a security from an exchange without asset distribution.
- LIQUIDATION: Dissolution of a company with distribution of remaining assets to shareholders.
- TICKER_CHANGE: Change of trading symbol, CUSIP, or company name without structural change.

Important distinctions:
- DELISTING vs LIQUIDATION: Delisting removes from exchange; liquidation distributes assets. If assets are distributed, it is LIQUIDATION.
- MERGER_CASH vs TENDER_OFFER: Tender offers are classified as MERGER_CASH unless an exchange ratio is present.
- 8-K filings with Item 8.01 are ambiguous and require careful keyword analysis.
- Confidence should be HIGH only when there is clear, unambiguous evidence.
- When multiple interpretations are possible, use MEDIUM or LOW confidence.

Respond ONLY with the JSON object. No additional text.`;

// --- Agent Class ---

const DEFAULT_CONFIG: AgentConfig = {
  apiKey: process.env.ANTHROPIC_API_KEY || '',
  model: process.env.AI_MODEL || 'claude-sonnet-4-20250514',
  maxTokens: parseInt(process.env.AI_MAX_TOKENS || '1024', 10),
  maxRetries: 3,
  baseDelayMs: 1000,
  cacheTtlSeconds: 3600, // 1 hour
};

export class CorpActionAgent {
  private client: Anthropic;
  private redis: Redis;
  private logger: Logger;
  private config: AgentConfig;
  private classificationCount = 0;
  private totalTokensUsed = 0;

  constructor(redis: Redis, logger: Logger, config?: Partial<AgentConfig>) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.client = new Anthropic({ apiKey: this.config.apiKey });
    this.redis = redis;
    this.logger = logger;
  }

  /**
   * Classify an ambiguous corporate action event using the AI agent.
   * Includes Redis caching, retry with exponential backoff, and graceful degradation.
   */
  async classifyAmbiguousEvent(
    event: RawCorporateActionEvent
  ): Promise<AgentClassificationResult | null> {
    const cacheKey = `ai:classify:${event.sourceType}:${event.sourceId}:${event.contentHash}`;

    // --- Check cache ---
    try {
      const cached = await this.redis.get(cacheKey);
      if (cached) {
        this.logger.info('AI classification cache hit', {
          ticker: event.ticker,
          sourceId: event.sourceId,
        });
        registry.counter('corpaction_ai_cache_hits_total', 'AI cache hits');
        const parsed = JSON.parse(cached) as AgentClassificationResult;
        return { ...parsed, cached: true };
      }
    } catch (cacheErr) {
      this.logger.warn('Redis cache read failed, proceeding without cache', {
        error: String(cacheErr),
      });
    }

    // --- Build prompt ---
    const userPrompt = this.buildUserPrompt(event);

    // --- Call API with retry + exponential backoff ---
    const startTime = Date.now();
    let lastError: Error | null = null;

    for (let attempt = 0; attempt < this.config.maxRetries; attempt++) {
      try {
        const response = await this.client.messages.create({
          model: this.config.model,
          max_tokens: this.config.maxTokens,
          system: CLASSIFICATION_SYSTEM_PROMPT,
          messages: [{ role: 'user', content: userPrompt }],
        });

        const latencyMs = Date.now() - startTime;

        // Extract text content from response
        const textBlock = response.content.find((block) => block.type === 'text');
        if (!textBlock || textBlock.type !== 'text') {
          throw new Error('No text content in AI response');
        }

        const parsed = JSON.parse(textBlock.text);
        this.validateResponse(parsed);
        const result: AgentClassificationResult = {
          actionType: parsed.actionType,
          confidence: parsed.confidence,
          reasoning: parsed.reasoning || '',
          signals: parsed.signals || [],
          params: parsed.params || {},
          modelUsed: this.config.model,
          latencyMs,
          cached: false,
        };

        // --- Track counters ---
        this.classificationCount++;
        this.totalTokensUsed += (response.usage?.input_tokens ?? 0) + (response.usage?.output_tokens ?? 0);

        // --- Publish metrics ---
        await this.publishMetrics(result, event, attempt + 1);

        // --- Write to cache ---
        try {
          await this.redis.set(cacheKey, JSON.stringify(result), 'EX', this.config.cacheTtlSeconds);
        } catch (cacheWriteErr) {
          this.logger.warn('Failed to write AI result to cache', {
            error: String(cacheWriteErr),
          });
        }

        this.logger.info('AI classification complete', {
          ticker: event.ticker,
          actionType: result.actionType,
          confidence: result.confidence,
          latencyMs,
          attempt: attempt + 1,
        });

        return result;
      } catch (err) {
        lastError = err instanceof Error ? err : new Error(String(err));
        this.logger.warn('AI classification attempt failed', {
          ticker: event.ticker,
          attempt: attempt + 1,
          maxRetries: this.config.maxRetries,
          error: lastError.message,
        });

        registry.counter('corpaction_ai_errors_total', 'AI classification errors', {
          error_type: lastError.name || 'unknown',
        });

        // Exponential backoff: baseDelay * 2^attempt
        if (attempt < this.config.maxRetries - 1) {
          const delay = this.config.baseDelayMs * Math.pow(2, attempt);
          await this.sleep(delay);
        }
      }
    }

    // --- Graceful degradation ---
    this.logger.error('AI classification failed after all retries, returning null for graceful degradation', {
      ticker: event.ticker,
      sourceId: event.sourceId,
      error: lastError?.message,
    });

    registry.counter('corpaction_ai_failures_total', 'AI total failures (all retries exhausted)');

    return null;
  }

  private buildUserPrompt(event: RawCorporateActionEvent): string {
    return `Classify the following corporate action event:

Ticker: ${event.ticker}
Company: ${event.companyName || 'Unknown'}
Source: ${event.sourceType}
Event Type (hint): ${event.eventType || 'UNKNOWN'}
ISIN: ${event.isin || 'N/A'}
Detected At: ${event.detectedAt instanceof Date ? event.detectedAt.toISOString() : String(event.detectedAt)}

Raw Data:
${JSON.stringify(event.rawData, null, 2)}

Analyze the above data and classify this corporate action. If the event type hint is ambiguous (e.g., CORPORATE_EVENT, PROXY_VOTE), use the raw data to determine the correct classification.`;
  }

  private buildClassificationPrompt(event: RawCorporateActionEvent): string {
    return this.buildUserPrompt(event);
  }

  private validateResponse(parsed: any): void {
    const validTypes = [
      'DIVIDEND', 'FORWARD_SPLIT', 'REVERSE_SPLIT',
      'MERGER_CASH', 'MERGER_STOCK', 'MERGER_HYBRID',
      'SPINOFF', 'DELISTING', 'LIQUIDATION', 'TICKER_CHANGE', 'UNKNOWN'
    ];
    if (!parsed || typeof parsed !== 'object') {
      throw new Error('Response is not a valid object');
    }
    if (!validTypes.includes(parsed.actionType)) {
      throw new Error(`Invalid actionType: ${parsed.actionType}`);
    }
    if (!['LOW', 'MEDIUM', 'HIGH'].includes(parsed.confidence)) {
      throw new Error(`Invalid confidence: ${parsed.confidence}`);
    }
  }

  private async publishMetrics(result: AgentClassificationResult, event: RawCorporateActionEvent, attempt: number): Promise<void> {
    registry.counter('corpaction_ai_classifications_total', 'AI classifications', {
      action_type: result.actionType,
      confidence: result.confidence,
    });
    registry.histogram(
      'corpaction_ai_latency_seconds',
      'AI classification latency',
      result.latencyMs / 1000,
      { model: this.config.model }
    );
    try {
      await this.redis.xadd(
        'corpaction:ai_metrics', '*',
        'ticker', event.ticker,
        'actionType', result.actionType,
        'confidence', result.confidence,
        'latencyMs', String(result.latencyMs),
        'model', this.config.model,
        'attempt', String(attempt)
      );
    } catch (metricsErr) {
      this.logger.warn('Failed to publish AI metrics to Redis stream', {
        error: String(metricsErr),
      });
    }
  }

  getStats(): { classifications: number; tokensUsed: number; model: string; cacheHitRate: string } {
    return {
      classifications: this.classificationCount,
      tokensUsed: this.totalTokensUsed,
      model: this.config.model,
      cacheHitRate: 'N/A',
    };
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
