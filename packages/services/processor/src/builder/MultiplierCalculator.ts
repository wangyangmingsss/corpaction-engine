export class MultiplierCalculator {
  private static readonly MULTIPLIER_BASE = BigInt(10) ** BigInt(18);

  static calculateNewMultiplier(
    currentMultiplier: bigint,
    numerator: bigint,
    denominator: bigint,
    isReverse: boolean
  ): bigint {
    if (isReverse) {
      return (currentMultiplier * denominator) / numerator;
    }
    return (currentMultiplier * numerator) / denominator;
  }

  static toUIAmount(rawBalance: bigint, multiplier: bigint): bigint {
    return (rawBalance * multiplier) / this.MULTIPLIER_BASE;
  }

  static fromUIAmount(uiAmount: bigint, multiplier: bigint): bigint {
    return (uiAmount * this.MULTIPLIER_BASE) / multiplier;
  }

  static formatMultiplier(multiplier: bigint): string {
    const whole = multiplier / this.MULTIPLIER_BASE;
    const fraction = multiplier % this.MULTIPLIER_BASE;
    const fractionStr = fraction.toString().padStart(18, '0').replace(/0+$/, '');
    return fractionStr ? `${whole}.${fractionStr}` : `${whole}`;
  }
}
