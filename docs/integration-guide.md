# Integration Guide

## Quick Start

Install the SDK:

```bash
npm install @corpaction/sdk
```

## Basic Usage

```typescript
import { CorpActionClient } from '@corpaction/sdk';

const client = new CorpActionClient({
  rpcUrl: 'https://rpc.chain.robinhood.com',
  registryAddress: '0x...',
  chainId: 42161, // Arbitrum
});

// Query pending actions for a token
const pending = await client.getPendingActions({ token: '0xTokenAddress' });

// Subscribe to corporate action events
const unsubscribe = client.onAction('0xTokenAddress', (action) => {
  console.log(`New ${action.type} for ${action.ticker}`);
});
```

## Dividend Claims

```typescript
const tx = await client.claimDividend(intentId, amount, merkleProof, signer);
```

## Event Subscriptions

| Event | Use Case |
|-------|----------|
| ActionProposed | Begin preparing for upcoming corporate action |
| ActionQueued | Action validated, will execute after timelock |
| ActionExecuted | Action completed — update your state |
| ActionCancelled | Action withdrawn — revert preparations |

## Integration Patterns by Protocol Type

- **Lending Protocol:** Listen for DELISTING proposals to begin liquidating collateral
- **Index Fund:** React to dividends (claim and reinvest) and mergers (rebalance)
- **Derivatives:** Adjust strike prices on SplitExecuted events
- **Portfolio Tracker:** Subscribe to all ActionExecuted events for display updates

## GMX Integration - Auto-Adjust Perp Contract Size on Split

A Solidity example showing how a GMX keeper bot monitors for SplitExecuted events via CrossChainReceiver to auto-adjust perpetual positions:

```solidity
// Example: GMX keeper bot monitoring for SplitExecuted events
import {CrossChainReceiver} from "@corpaction/contracts/integrations/CrossChainReceiver.sol";

contract GmxSplitAdjuster {
    CrossChainReceiver public receiver;
    
    // Interface for GMX position management
    interface IGmxPositionRouter {
        function adjustPositionsForSplit(address token, uint256 splitRatio) external;
    }
    
    IGmxPositionRouter public positionRouter;

    // Listen for CorporateActionReceived where actionType == FORWARD_SPLIT
    function onCorporateAction(
        bytes32 intentId,
        uint8 actionType,
        address targetToken,
        bytes memory executionData
    ) external {
        if (actionType == 1) { // FORWARD_SPLIT
            (uint256 oldMultiplier, uint256 newMultiplier) =
                abi.decode(executionData, (uint256, uint256));

            uint256 splitRatio = newMultiplier / oldMultiplier;

            // Adjust all open positions for this token
            // Contract size / splitRatio, strike price * splitRatio
            positionRouter.adjustPositionsForSplit(
                targetToken, splitRatio
            );
        }
    }
}
```

## Uniswap V3 - Auto-Remove Liquidity on Delisting

```solidity
// Example: Uniswap V3 liquidity guard for delisting events
contract UniswapDelistingGuard {
    CrossChainReceiver public receiver;
    
    interface INonfungiblePositionManager {
        function positions(uint256 tokenId) external view returns (
            uint96 nonce, address operator, address token0, address token1,
            uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        );
        function decreaseLiquidity(bytes calldata params) external payable returns (uint256, uint256);
        function collect(bytes calldata params) external payable returns (uint256, uint256);
    }
    
    INonfungiblePositionManager public positionManager;

    function onDelistingWarning(
        bytes32 intentId,
        address targetToken,
        uint256 freezeTimestamp
    ) external {
        require(block.timestamp < freezeTimestamp, "Too late to withdraw");
        
        // Find all Uniswap V3 positions involving this token
        // Remove liquidity before the freeze timestamp
        // Convert to USDC via the liquidation price
        
        // Implementation: iterate tracked position IDs, filter by token,
        // call decreaseLiquidity + collect for each matching position
    }
}
```
