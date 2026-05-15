import { ethers } from 'ethers';

export class SigningService {
  private wallet: ethers.Wallet;

  constructor(privateKey: string) {
    this.wallet = new ethers.Wallet(privateKey);
  }

  get address(): string {
    return this.wallet.address;
  }

  async signMessage(message: string | Uint8Array): Promise<string> {
    return await this.wallet.signMessage(message);
  }

  async signIntentProposal(intent: {
    intentId: string;
    actionType: number;
    targetToken: string;
    ticker: string;
    isin: string;
    recordDate: number;
    exDate: number;
    effectiveDate: number;
    actionParams: string;
    sourceAttestation: string;
  }): Promise<string> {
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ['bytes32', 'uint8', 'address', 'string', 'string', 'uint256', 'uint256', 'uint256', 'bytes', 'bytes32'],
      [
        intent.intentId, intent.actionType, intent.targetToken,
        intent.ticker, intent.isin, intent.recordDate,
        intent.exDate, intent.effectiveDate, intent.actionParams,
        intent.sourceAttestation,
      ]
    );
    const hash = ethers.keccak256(encoded);
    return await this.wallet.signMessage(ethers.getBytes(hash));
  }

  async signValidation(
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

  async signEmergencyResume(chainId: number, registryAddress: string): Promise<string> {
    const hash = ethers.keccak256(
      ethers.solidityPacked(
        ['string', 'uint256', 'address'],
        ['EMERGENCY_RESUME', chainId, registryAddress]
      )
    );
    return await this.wallet.signMessage(ethers.getBytes(hash));
  }
}
