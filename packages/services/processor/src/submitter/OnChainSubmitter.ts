import { ethers } from 'ethers';
import { ActionIntentData } from '../builder/ActionIntentBuilder';

const ACTION_REGISTRY_ABI = [
  'function proposeAction(tuple(bytes32 intentId, uint8 actionType, address targetToken, string ticker, string isin, uint256 recordDate, uint256 exDate, uint256 effectiveDate, bytes actionParams, bytes32 sourceAttestation, uint8 state, uint256 createdAt, uint256 executedAt) intent, bytes signature) external returns (bytes32)',
  'function validateAction(bytes32 intentId, bytes signature) external',
  'function executeAction(bytes32 intentId) external',
  'function getAction(bytes32 intentId) external view returns (tuple(bytes32 intentId, uint8 actionType, address targetToken, string ticker, string isin, uint256 recordDate, uint256 exDate, uint256 effectiveDate, bytes actionParams, bytes32 sourceAttestation, uint8 state, uint256 createdAt, uint256 executedAt))',
  'function getExecutionTime(bytes32 intentId) external view returns (uint256)',
  'event ActionProposed(bytes32 indexed intentId, uint8 indexed actionType, address indexed targetToken, string ticker)',
  'event ActionQueued(bytes32 indexed intentId, uint256 executionTime)',
  'event ActionExecuted(bytes32 indexed intentId, uint8 indexed actionType, address indexed targetToken, bytes result)',
];

export class OnChainSubmitter {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private registry: ethers.Contract;

  constructor(rpcUrl: string, privateKey: string, registryAddress: string) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl);
    this.wallet = new ethers.Wallet(privateKey, this.provider);
    this.registry = new ethers.Contract(registryAddress, ACTION_REGISTRY_ABI, this.wallet);
  }

  async submitIntent(intentData: ActionIntentData): Promise<string> {
    const intent = {
      intentId: intentData.intentId,
      actionType: intentData.actionType,
      targetToken: intentData.targetToken,
      ticker: intentData.ticker,
      isin: intentData.isin,
      recordDate: intentData.recordDate,
      exDate: intentData.exDate,
      effectiveDate: intentData.effectiveDate,
      actionParams: intentData.actionParams,
      sourceAttestation: intentData.sourceAttestation,
      state: 0, // PROPOSED
      createdAt: 0,
      executedAt: 0,
    };

    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ['tuple(bytes32,uint8,address,string,string,uint256,uint256,uint256,bytes,bytes32,uint8,uint256,uint256)'],
      [Object.values(intent)]
    );
    const hash = ethers.keccak256(encoded);
    const signature = await this.wallet.signMessage(ethers.getBytes(hash));

    const tx = await this.registry.proposeAction(intent, signature);
    const receipt = await tx.wait();

    return receipt.hash;
  }

  async executeIntent(intentId: string): Promise<string> {
    const executionTime = await this.registry.getExecutionTime(intentId);
    const now = Math.floor(Date.now() / 1000);

    if (now < Number(executionTime)) {
      throw new Error(`Timelock not expired. Ready at ${executionTime}`);
    }

    const tx = await this.registry.executeAction(intentId);
    const receipt = await tx.wait();
    return receipt.hash;
  }

  async getIntentState(intentId: string): Promise<number> {
    const intent = await this.registry.getAction(intentId);
    return Number(intent.state);
  }
}
