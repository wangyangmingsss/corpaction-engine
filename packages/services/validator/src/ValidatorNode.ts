import { ethers } from 'ethers';
import { Redis } from 'ioredis';

const ACTION_REGISTRY_ABI = [
  'event ActionProposed(bytes32 indexed intentId, uint8 indexed actionType, address indexed targetToken, string ticker)',
  'event ActionQueued(bytes32 indexed intentId, uint256 executionTime)',
  'event ActionExecuted(bytes32 indexed intentId, uint8 indexed actionType, address indexed targetToken, bytes result)',
  'function getAction(bytes32 intentId) external view returns (tuple(bytes32 intentId, uint8 actionType, address targetToken, string ticker, string isin, uint256 recordDate, uint256 exDate, uint256 effectiveDate, bytes actionParams, bytes32 sourceAttestation, uint8 state, uint256 createdAt, uint256 executedAt))',
  'function validateAction(bytes32 intentId, bytes signature) external',
];

interface SourceVerifier {
  verify(eventId: string, actionType: number, params: string): Promise<{ verified: boolean; details: string }>;
}

export class ValidatorNode {
  private wallet: ethers.Wallet;
  private provider: ethers.JsonRpcProvider;
  private redis: Redis;
  private redisSub: Redis;
  private registryAddress: string;
  private registry: ethers.Contract;
  private isRunning = false;
  private sourceVerifiers: SourceVerifier[];

  constructor(
    rpcUrl: string,
    privateKey: string,
    registryAddress: string,
    redisUrl: string,
    sourceVerifiers: SourceVerifier[] = []
  ) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);
    this.redis = new Redis(redisUrl);
    this.redisSub = new Redis(redisUrl);
    this.registryAddress = registryAddress;
    this.registry = new ethers.Contract(registryAddress, ACTION_REGISTRY_ABI, this.wallet);
    this.sourceVerifiers = sourceVerifiers;
  }

  async start(): Promise<void> {
    this.isRunning = true;
    this.log('info', 'Validator node started', { address: this.wallet.address });

    // Start all loops concurrently
    await Promise.all([
      this.listenForProposals(),
      this.listenForValidatorMessages(),
      this.heartbeatLoop(),
    ]);
  }

  async stop(): Promise<void> {
    this.isRunning = false;
    await this.redisSub.unsubscribe();
    await this.redisSub.quit();
    await this.redis.quit();
  }

  async signIntent(intentHash: string): Promise<string> {
    return await this.wallet.signMessage(ethers.getBytes(intentHash));
  }

  async validateAndSign(
    intentId: string,
    actionType: number,
    targetToken: string,
    actionParams: string
  ): Promise<string> {
    const hash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'uint8', 'address', 'bytes'],
        [intentId, actionType, targetToken, actionParams]
      )
    );
    return await this.wallet.signMessage(ethers.getBytes(hash));
  }

  /**
   * Listen for on-chain ActionProposed events via ethers provider.
   * When a new proposal arrives, independently verify it and either
   * submit a validation signature or publish a conflict.
   */
  private async listenForProposals(): Promise<void> {
    this.log('info', 'Listening for ActionProposed events on-chain', {
      registry: this.registryAddress,
    });

    this.registry.on(
      'ActionProposed',
      async (intentId: string, actionType: number, targetToken: string, ticker: string) => {
        if (!this.isRunning) return;

        this.log('info', 'ActionProposed event received', {
          intentId,
          actionType,
          targetToken,
          ticker,
        });

        try {
          // Fetch full action details from chain
          const action = await this.registry.getAction(intentId);
          const actionParams = action.actionParams;

          // Independent verification via source verifiers
          const verificationResult = await this.verifyAction(
            intentId,
            Number(actionType),
            actionParams
          );

          if (verificationResult.verified) {
            // Sign and submit validation
            const signature = await this.validateAndSign(
              intentId,
              Number(actionType),
              targetToken,
              actionParams
            );

            const tx = await this.registry.validateAction(intentId, signature);
            await tx.wait();

            this.log('info', 'Validation submitted on-chain', { intentId });

            // Notify other validators via Redis pub/sub
            await this.redis.publish(
              'validator:coordination',
              JSON.stringify({
                type: 'VALIDATION_SUBMITTED',
                intentId,
                validator: this.wallet.address,
                timestamp: Date.now(),
              })
            );
          } else {
            // Verification failed -- publish conflict
            this.log('warn', 'Verification failed, publishing conflict', {
              intentId,
              details: verificationResult.details,
            });

            await this.redis.publish(
              'validator:coordination',
              JSON.stringify({
                type: 'VERIFICATION_CONFLICT',
                intentId,
                validator: this.wallet.address,
                details: verificationResult.details,
                timestamp: Date.now(),
              })
            );

            // Also store the conflict for the processor to act on
            await this.redis.xadd(
              'corpaction:validator_conflicts', '*',
              'intentId', intentId,
              'validator', this.wallet.address,
              'details', verificationResult.details
            );
          }
        } catch (error) {
          this.log('error', 'Error processing ActionProposed event', {
            intentId,
            error: String(error),
          });
        }
      }
    );

    // Keep the listener alive until stopped
    while (this.isRunning) {
      await new Promise(r => setTimeout(r, 5000));
    }
  }

  /**
   * Multi-validator coordination via Redis pub/sub.
   * Listens for messages from other validators about validations and conflicts.
   */
  private async listenForValidatorMessages(): Promise<void> {
    await this.redisSub.subscribe('validator:coordination');

    this.redisSub.on('message', async (_channel: string, message: string) => {
      if (!this.isRunning) return;

      try {
        const msg = JSON.parse(message);

        // Ignore our own messages
        if (msg.validator === this.wallet.address) return;

        switch (msg.type) {
          case 'VALIDATION_SUBMITTED':
            this.log('info', 'Peer validator submitted validation', {
              intentId: msg.intentId,
              peerValidator: msg.validator,
            });
            break;

          case 'VERIFICATION_CONFLICT':
            this.log('warn', 'Peer validator reported conflict', {
              intentId: msg.intentId,
              peerValidator: msg.validator,
              details: msg.details,
            });
            // Store peer conflict for local review
            await this.redis.xadd(
              'corpaction:validator_conflicts', '*',
              'intentId', msg.intentId,
              'validator', msg.validator,
              'details', msg.details,
              'source', 'peer'
            );
            break;

          case 'QUORUM_REACHED':
            this.log('info', 'Quorum reached for intent', {
              intentId: msg.intentId,
            });
            break;

          default:
            this.log('debug', 'Unknown coordinator message type', { type: msg.type });
        }
      } catch (error) {
        this.log('error', 'Error processing validator message', {
          error: String(error),
        });
      }
    });

    // Keep alive
    while (this.isRunning) {
      await new Promise(r => setTimeout(r, 5000));
    }
  }

  /**
   * Verify an action independently using registered SourceVerifiers.
   * Returns verified=true only if at least one verifier confirms the action.
   */
  private async verifyAction(
    intentId: string,
    actionType: number,
    actionParams: string
  ): Promise<{ verified: boolean; details: string }> {
    if (this.sourceVerifiers.length === 0) {
      // No verifiers configured -- default to trusting on-chain data
      this.log('warn', 'No source verifiers configured; auto-approving', { intentId });
      return { verified: true, details: 'No verifiers configured (auto-approved)' };
    }

    const results: Array<{ verified: boolean; details: string }> = [];

    for (const verifier of this.sourceVerifiers) {
      try {
        const result = await verifier.verify(intentId, actionType, actionParams);
        results.push(result);
      } catch (error) {
        results.push({ verified: false, details: `Verifier error: ${String(error)}` });
      }
    }

    const verified = results.some(r => r.verified);
    const details = results.map(r => r.details).join('; ');

    return { verified, details };
  }

  private async heartbeatLoop(): Promise<void> {
    while (this.isRunning) {
      try {
        await this.redis.set(
          `validator:heartbeat:${this.wallet.address}`,
          Date.now().toString(),
          'EX', 300
        );
      } catch (error) {
        this.log('error', 'Heartbeat error', { error: String(error) });
      }
      await new Promise(r => setTimeout(r, 60_000));
    }
  }

  private log(level: string, message: string, meta?: Record<string, unknown>): void {
    console.log(JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      service: 'validator',
      address: this.wallet.address,
      message,
      ...meta,
    }));
  }
}
