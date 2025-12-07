# RecorrHook 🔄

> **FX Corridor Hook for Uniswap V4**  
> Async intents + CoW matching + Dynamic fees for stablecoin corridors

[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-e6e6e6?logo=solidity)](https://soliditylang.org/)

## 🎯 Overview

RecorrHook is a specialized Uniswap V4 hook designed for cross-border stablecoin corridors. It implements:

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
