# RecorrHook

> FX Corridor Hook for Uniswap V4  
> Async intents + CoW matching + Dynamic fees for stablecoin corridors

[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-e6e6e6?logo=solidity)](https://soliditylang.org/)
[![Deployed on Sepolia](https://img.shields.io/badge/Deployed-Sepolia-blue)](https://sepolia.etherscan.io/address/0xfD2984eFe82c1291BAeec241A7D47ef0b87F80c0)

## Hookathon Submission - Uniswap Hook Incubator V7

**Project Name:** RecorrHook  
**Category:** Cross-Border Remittances & CoW Optimization  
**Submission Date:** December 11, 2025  
**Author:** Daniel ([@danelerr](https://github.com/danelerr))

### Links

- **Smart Contracts:** [github.com/danelerr/recorr-hook](https://github.com/danelerr/recorr-hook)
- **Live Demo:** [recorr-hook-frontend.vercel.app](https://recorr-hook-frontend.vercel.app/)
- **Frontend Repo:** [github.com/danelerr/recorr-hook-frontend](https://github.com/danelerr/recorr-hook-frontend)
- **Video Demo:** [Watch on YouTube](https://youtu.be/BelSjPyDTxk)
- **Pitch Deck:** [View on Canva](https://www.canva.com/design/DAG63IzsR5s/En0mDD2VR4ujJvvsEc_7EQ/view?utm_content=DAG63IzsR5s&utm_campaign=designshare&utm_medium=link2&utm_source=uniquelinks&utlId=he74500b53d)

---

## Overview

RecorrHook is a Uniswap V4 hook for cross-border stablecoin corridors (e.g., USD → Bolivia remittances). Key features:

- **Async Swap Intents**: Convert swaps into deferred intents for optimized settlement
- **CoW Matching**: Peer-to-peer netting of opposing flows before hitting the AMM
- **Dynamic Fees**: Adjust fees based on directional flow to protect LPs
- **Bridge Integration**: Cross-chain corridors via periphery router
- **AVS-Ready**: Architecture supports future EigenLayer integration

### Problem

Cross-border remittances face:
- High slippage on unidirectional flows
- Expensive fees (3-10% typical)
- IL risk for LPs in unbalanced pools
- No flow coordination

### Solution

RecorrHook matches opposing intents peer-to-peer before AMM execution:
- Users get better prices on matched portions
- LPs are protected via dynamic fees
- Operators earn settlement fees

### Documentation

- **[DEPLOYED_CONTRACTS.md](./DEPLOYED_CONTRACTS.md)** - All deployed addresses on Sepolia
- **[DIAGRAMS_MERMAID.md](./DIAGRAMS_MERMAID.md)** - Visual diagrams

Built for Uniswap Hook Incubator V7

---

## Quick Start

### Testing Locally
```bash
# 1. Install dependencies
forge install

# 2. Run tests (57 tests passing)
forge test

# 3. Build contracts
forge build
```

### Using Sepolia Deployment

All contracts are deployed and operational on Sepolia testnet. See [DEPLOYED_CONTRACTS.md](./DEPLOYED_CONTRACTS.md) for complete addresses.

**Get Test Tokens:**
```bash
# Get USDC from faucet
cast send 0x9aD20ACF1E3592efF473B510603f5f647994cE9b "faucet()" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --private-key <your-key>

# Get BOB from faucet  
cast send 0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D "faucet()" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --private-key <your-key>
```

**Core Contracts (Sepolia):**
- RecorrHook: `0xfD2984eFe82c1291BAeec241A7D47ef0b87F80c0`
- RecorrRouter: `0xA1ee6ACBF604e5c165129694340a9124417DCBf2`
- MockUSDC: `0x9aD20ACF1E3592efF473B510603f5f647994cE9b`
- MockBOB: `0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D`
- Pool ID: `0x3aa9f240666b603b79bd9f409b58b326b30e308c6792065411d368509de145f3`

**Frontend Configuration:**  
The frontend is configured to use these Sepolia addresses. See [recorr-hook-frontend](https://github.com/danelerr/recorr-hook-frontend) repository.

---

**Note**: This is a Hookathon proof-of-concept. Some features are experimental.

## Important Notes for Production

### PoC Design Choices

**Async Mode Behavior**
- Current: Intents created + swap executes (coordination layer)
- Production: Dedicated router to create intents without swap execution
- Reason: Demonstrates CoW concept for Hookathon scope

**tx.origin Usage**
Using `tx.origin` for intent owner is a **hackathon shortcut** only:
- Used to simplify demo without custom router modifications
- Production version should:
  - Pass `owner` explicitly via `hookData`, OR
  - Use a dedicated router that sets `msg.sender` as owner
- See: [Consensys Best Practices on tx.origin](https://consensys.github.io/smart-contract-best-practices/development-recommendations/solidity-specific/tx-origin/)

### Net Flow Accumulation
- Current implementation: Simple accumulator across all time
- Production consideration: Periodic reset via `resetNetFlow()` or time-windowed scheme
- Operator or AVS could manage flow resets based on corridor activity patterns

### hookData Format
Async intents use: `mode (1 byte) + abi.encode(minOut, deadline) (64 bytes) = 65 bytes total`

## Future Roadmap: EigenLayer AVS Integration

The next major enhancement will integrate **EigenLayer AVS** (Actively Validated Services) to create a decentralized solver network:

#### Why EigenLayer AVS?

1. **Decentralized Solver Network**:
   - Replace centralized solver with distributed network of operators
   - Operators stake ETH/restaked assets via EigenLayer
   - Economic security proportional to staked value

2. **Cryptoeconomic Guarantees**:
   - **Slashing for Malicious Behavior**: Operators lose stake if they:
     - Submit invalid settlements (expired intents, incorrect amounts)
     - Front-run users by reordering intents
     - Fail to settle within SLA timeframe
   - **Incentive Alignment**: Operators earn rewards for correct, timely settlements

3. **Censorship Resistance**:
   - Multiple operators compete to settle batches
   - No single point of failure or censorship
   - Fallback mechanisms if operators misbehave

4. **Scalability**:
   - Horizontal scaling via operator pool
   - Parallel batch processing across operators
   - Load balancing based on corridor activity

#### Integration Architecture

```
RecorrHook (On-chain)
    |
    v
EigenLayer AVS (Off-chain Operator Network)
    |
    +-> Operator 1: Monitors intents, proposes batches
    +-> Operator 2: Validates settlements, challenges fraud
    +-> Operator 3: Executes cross-chain coordination
    |
    v
Slashing Contract (On-chain)
    - Stake: Operators deposit ETH/restaked LSTs
    - Challenge Period: Users can dispute settlements
    - Slashing: Malicious operators lose stake
```

#### Implementation Plan

- **Phase 1**: Proof-of-Concept AVS operator (Hackathon scope)
  - Single trusted operator for demo
  - Settlement logic in off-chain service
  - On-chain verification in RecorrHook

- **Phase 2**: Multi-Operator Network (Post-Hackathon)
  - Deploy EigenLayer AVS contracts
  - Operator registration and staking
  - Batch auction mechanism (operators bid on settlements)

- **Phase 3**: Full Decentralization
  - Slashing conditions and dispute resolution
  - Economic modeling for operator incentives
  - Cross-chain settlement coordination via AVS

#### Why Not Now?

- **Time Constraints**: Hookathon deadline prioritizes core functionality
- **Complexity**: EigenLayer AVS integration requires careful security design
- **Dependencies**: Requires deployed EigenLayer infrastructure on target chains

**Bottom Line**: RecorrHook's architecture is AVS-ready. The current centralized solver is a bootstrapping mechanism that will be replaced with a decentralized, cryptoeconomically secured operator network via EigenLayer.

---

## Architecture & Security

### System Components

**RecorrHook** (Core Hook Contract)
- Async intent creation via `beforeSwap`
- Batch settlement with CoW matching algorithm
- Dynamic fee calculation based on net flow imbalances
- Best-effort validation (skips invalid intents, no batch revert)

**RecorrRouter** (Periphery Contract)
- Unified `swap()` and `swapAndBridge()` interface
- User-friendly entry point for creating intents
- Slippage protection via `minAmountOut`

**MockBridge** (Demo Contract)
- Cross-chain corridor demonstration
- Placeholder for production bridge integrations (CCTP, LayerZero, etc.)

### Design Choices & Limitations (Hackathon Build)

**Intents + Swap Execution**
- Current: Intents created AND swap executes (coordination layer)
- Production: Dedicated router to create intents WITHOUT executing swap
- Rationale: Demonstrates CoW concept while maintaining generic router compatibility

**tx.origin for Owner**
- Current: Using `tx.origin` to identify intent creator
- Production: Router passes owner explicitly via `hookData` or as parameter
- Rationale: Simplifies demo without custom router; production follows best practices

**No Token Transfers in Hook**
- Settlement is logical only (marks intents as settled)
- Actual token transfers happen in PoolManager or external router
- Rationale: Hook focuses on coordination, not custody

**Simple Net Flow Accumulator**
- Current: Accumulates net flow across all time
- Production: Time-windowed or periodic reset via `resetNetFlow()`
- Rationale: Illustrates dynamic fee concept; production needs decay/reset strategy

### Security Posture

**Access Control**
- Hook only callable by PoolManager (enforced by `BaseHook`)
- Owner-only functions: `setCorridorPool`, `setPoolFeeParams`, `resetNetFlow`
- No external token approvals required

**Asset Safety**
- No token custody in hook contract
- No token transfers in callbacks
- Settlement logic is bookkeeping only

**Best-Effort Validation**
- Batch settlement skips invalid intents (expired, settled, non-existent)
- Never reverts entire batch for single bad intent
- Maximizes settlement throughput

**CoW Algorithm Safety**
- Symmetric matching: `min(totalZeroForOne, totalOneForZero)`
- No price manipulation possible (prices come from PoolManager)
- Net amount to AMM is always >= 0

**Production Considerations**
- Audit recommendations: Remove `tx.origin`, implement proper owner passing
- Consider intent expiration cleanup mechanism
- Add comprehensive events for off-chain monitoring
- Implement access control for solver role (currently open)

---

## Additional Resources

- **Demo Script**: `script/CoWDemo.s.sol`
- **Deployment Script**: `script/DeployRecorrHook.s.sol`
- **Tests**: `test/RecorrHook.t.sol`
- **Uniswap V4 Docs**: https://docs.uniswap.org/contracts/v4/overview
- **EigenLayer AVS**: https://docs.eigenlayer.xyz/eigenlayer/avs-guides/avs-developer-guide

