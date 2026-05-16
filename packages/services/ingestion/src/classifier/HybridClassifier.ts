import { Redis } from 'ioredis';
import { Logger } from '../utils/Logger';
import { registry } from '../metrics';
import {
  EventClassifier,
  ActionType,
  ConfidenceLevel,
  ClassificationResult,
} from '../classifier/EventClassifier';
import { CorpActionAgent, AgentClassificationResult } from '../agent/CorpActionAgent';
import { RawCorporateActionEvent } from '../sources/ICorporateActionSource';

// --- Interfaces ---

export interface HybridClassificationResult {
  actionType: ActionType;
  confidence: ConfidenceLevel;
  signals: string[];
  params: Record<string, unknown>;
  source: 'RULE_ONLY' | 'AI_ONLY' | 'CONSENSUS' | 'RULE_FALLBACK';
  ruleResult: ClassificationResult | null;
  aiResult: AgentClassificationResult | null;
  flaggedForReview: boolean;
}

// --- Hybrid Classifier ---

export class HybridClassifier {
  private ruleClassifier: EventClassifier;
  private aiAgent: CorpActionAgent;
  private logger: Logger;

  constructor(redis: Redis, logger: Logger) {
    this.ruleClassifier = new EventClassifier(logger);
    this.aiAgent = new CorpActionAgent(redis, logger);
    this.logger = logger;
  }

  /**
   * Classify an event using hybrid rule + AI approach.
   *
   * Strategy:
   * 1. Run rule-based classifier first.
   * 2. If HIGH confidence from rules, skip AI (zero cost).
   * 3. If LOW/MEDIUM confidence (or null), invoke AI agent.
   * 4. Consensus logic:
   *    - Both agree on actionType -> HIGH confidence, source = CONSENSUS
   *    - Disagree -> flag for human review
   * 5. If AI fails, gracefully fall back to rule-based result.
   */
  async classify(event: RawCorporateActionEvent): Promise<HybridClassificationResult | null> {
    const startTime = Date.now();

    // --- Step 1: Rule-based classification ---
    const ruleResult = this.ruleClassifier.classify(event);

    // --- Step 2: HIGH confidence from rules -> skip AI ---
    if (ruleResult && ruleResult.confidence === 'HIGH') {
      this.logger.info('Rule-based HIGH confidence, skipping AI', {
        ticker: event.ticker,
        actionType: ruleResult.actionType,
      });

      registry.counter('corpaction_hybrid_rule_only_total', 'Events classified by rules only');

      return {
        actionType: ruleResult.actionType,
        confidence: 'HIGH',
        signals: ruleResult.signals,
        params: ruleResult.params,
        source: 'RULE_ONLY',
        ruleResult,
        aiResult: null,
        flaggedForReview: false,
      };
    }

    // --- Step 3: LOW/MEDIUM or null -> invoke AI ---
    this.logger.info('Rule confidence insufficient, invoking AI agent', {
      ticker: event.ticker,
      ruleActionType: ruleResult?.actionType || 'NONE',
      ruleConfidence: ruleResult?.confidence || 'NONE',
    });

    let aiResult: AgentClassificationResult | null = null;
    try {
      aiResult = await this.aiAgent.classifyAmbiguousEvent(event);
    } catch (aiErr) {
      this.logger.error('AI agent threw unexpected error', {
        ticker: event.ticker,
        error: String(aiErr),
      });
    }

    // --- Step 5: AI failed -> graceful fallback to rule result ---
    if (!aiResult) {
      this.logger.warn('AI agent returned null, falling back to rule-based result', {
        ticker: event.ticker,
      });

      registry.counter('corpaction_hybrid_ai_fallback_total', 'AI failures with rule fallback');

      if (ruleResult) {
        return {
          actionType: ruleResult.actionType,
          confidence: ruleResult.confidence,
          signals: [...ruleResult.signals, 'ai_fallback'],
          params: ruleResult.params,
          source: 'RULE_FALLBACK',
          ruleResult,
          aiResult: null,
          flaggedForReview: ruleResult.confidence === 'LOW',
        };
      }

      // Both rule and AI failed
      return null;
    }

    // --- Step 4: Consensus logic ---
    if (ruleResult) {
      const agree = ruleResult.actionType === aiResult.actionType;

      if (agree) {
        // Both agree -> HIGH confidence consensus
        this.logger.info('Rule and AI agree on classification', {
          ticker: event.ticker,
          actionType: aiResult.actionType,
        });

        registry.counter('corpaction_hybrid_consensus_total', 'Rule+AI consensus classifications');

        return {
          actionType: aiResult.actionType,
          confidence: 'HIGH',
          signals: [
            ...new Set([...ruleResult.signals, ...aiResult.signals]),
            'rule_ai_consensus',
          ],
          params: { ...ruleResult.params, ...aiResult.params },
          source: 'CONSENSUS',
          ruleResult,
          aiResult,
          flaggedForReview: false,
        };
      } else {
        // Disagree -> flag for human review
        this.logger.warn('Rule and AI disagree, flagging for review', {
          ticker: event.ticker,
          ruleActionType: ruleResult.actionType,
          aiActionType: aiResult.actionType,
          aiConfidence: aiResult.confidence,
        });

        registry.counter('corpaction_hybrid_disagreement_total', 'Rule+AI disagreements');

        // Prefer AI result but flag for review
        return {
          actionType: aiResult.actionType,
          confidence: 'LOW',
          signals: [
            ...aiResult.signals,
            'rule_ai_disagreement',
            `rule_said_${ruleResult.actionType}`,
          ],
          params: { ...ruleResult.params, ...aiResult.params, ruleActionType: ruleResult.actionType },
          source: 'CONSENSUS',
          ruleResult,
          aiResult,
          flaggedForReview: true,
        };
      }
    }

    // No rule result, AI only
    this.logger.info('No rule result, using AI-only classification', {
      ticker: event.ticker,
      actionType: aiResult.actionType,
      confidence: aiResult.confidence,
    });

    registry.counter('corpaction_hybrid_ai_only_total', 'AI-only classifications');

    return {
      actionType: aiResult.actionType,
      confidence: aiResult.confidence,
      signals: [...aiResult.signals, 'ai_only'],
      params: aiResult.params,
      source: 'AI_ONLY',
      ruleResult: null,
      aiResult,
      flaggedForReview: aiResult.confidence === 'LOW',
    };
  }
}
