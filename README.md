# RecorrHook 🔄

> **FX Corridor Hook for Uniswap V4**  
> Async intents + CoW matching + Dynamic fees for stablecoin corridors

[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-e6e6e6?logo=solidity)](https://soliditylang.org/)

## 🎯 Overview

RecorrHook is a spcialized Uniswap V4 hook designed for cross-border stablecoin corridors. It implements:

- **Async Swap Intents**: Convert swaps into deferred intents for optimized settlement
- **CoW Matching**: Peer-to-peer netting of opposing flows before hitting the AMM
- **Dynamic Corridor Fees**: Protect LPs from directional flow risks with adaptive fees
- **Swap & Bridge Integration**: Seamless cross-chain corridors via periphery router
- **AVS-Ready**: Designed for future EigenLayer solver integration

## 👤 Author

**Daniel** ([@danelerr](https://github.com/danelerr))

Built for Uniswap Hook Incubator V7 🦄

---

**Note**: This project is under active development for the Hookathon. Some features are incomplete or experimental.

## ⚠️ Important Notes for Production

### Async Mode Behavior (PoC)
Currently, **async mode creates intents but DOES NOT prevent the swap from executing**:
- Returning `ZERO_DELTA` in `beforeSwap` does not cancel the swap in Uniswap v4
- The PoolManager still executes the swap normally after creating the intent
- For production, use one of these approaches:
  - **Recommended**: Dedicated router function to create intents without calling `PoolManager.swap()`
  - **Alternative**: Revert in `beforeSwap` for async mode (breaks compatibility with generic routers)

### tx.origin Usage (Temporary)
Using `tx.origin` for intent owner is a **hackathon shortcut** only:
- Production version should:
  - Pass `owner` explicitly via `hookData`, OR
  - Use a dedicated router that sets `msg.sender` as owner
- See: [Consensys Best Practices on tx.origin](https://consensys.github.io/smart-contract-best-practices/development-recommendations/solidity-specific/tx-origin/)

### hookData Format
Async intents require exact encoding:
```solidity
bytes memory hookData = abi.encodePacked(
    uint8(0x01),                    // Mode: async
    abi.encode(                     // ABI-encoded params (64 bytes)
        uint256 minOut,             // Minimum output amount
        uint48 deadline             // Deadline timestamp
    )
);
// Total: 65 bytes (1 + 64)
```

