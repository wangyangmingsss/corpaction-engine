import { ethers } from 'ethers';
import { Redis } from 'ioredis';

export class ValidatorNode {
  private wallet: ethers.Wallet;
  private provider: ethers.JsonRpcProvider;
  private redis: Redis;
  private registryAddress: string;
  private isRunning = false;

  constructor(
    rpcUrl: string,
    privateKey: string,
    registryAddress: string,
    redisUrl: string
  ) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);
    this.redis = new Redis(redisUrl);
    this.registryAddress = registryAddress;
  }

  async start(): Promise<void> {
    this.isRunning = true;
    console.log(JSON.stringify({
      timestamp: new Date().toISOString(),
      level: 'info',
      service: 'validator',
      message: 'Validator node started',
      address: this.wallet.address,
    }));

    await this.heartbeatLoop();
  }

  async stop(): Promise<void> {
    this.isRunning = false;
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

  private async heartbeatLoop(): Promise<void> {
    while (this.isRunning) {
      try {
        await this.redis.set(
          `validator:heartbeat:${this.wallet.address}`,
          Date.now().toString(),
          'EX', 300
        );
      } catch (error) {
        console.error('Heartbeat error:', error);
      }
      await new Promise(r => setTimeout(r, 60_000));
    }
  }
}
