# RecorrHook - Visual Diagrams (Mermaid)

This document contains interactive diagrams in Mermaid format that can be visualized directly on GitHub.

---

## 1. General System Architecture

```mermaid
graph TB
    subgraph "Frontend (React + Wagmi)"
        UI[Swap Widget]
        IntentsUI[My Intents Dashboard]
        OperatorUI[Operator Page]
    end

    subgraph "Blockchain - Sepolia Testnet"
        PM[PoolManager<br/>Uniswap v4]
        Hook[RecorrHook<br/>0xfD29...80c0]
        Router[RecorrRouter<br/>0xA1ee...CBf2]
        Bridge[MockBridge<br/>0x0612...20e8]
        
        subgraph "Tokens"
            USDC[MockUSDC<br/>0x9aD2...9b]
            BOB[MockBOB<br/>0xE58D...6D]
        end
    end

    subgraph "Off-Chain"
        Operator[Operator EOA<br/>today<br/>AVS roadmap]
        Indexer[Event Indexer]
    end

    UI -->|1. Create Intent| Router
    UI -->|2. Instant Swap| Router
    Router -->|swap hookData| PM
    PM -->|beforeSwap| Hook
    PM -->|afterSwap| Hook
    Hook -->|Store Intent| Hook
    
    Hook -->|emit IntentCreated| Indexer
    Indexer -->|Monitor Events| Operator
    Operator -->|settleBatch| Hook
    Hook -->|CoW Matching| Hook
    
    Router -->|bridgeTokens| Bridge
    Bridge -->|Cross-chain| Bridge
    
    IntentsUI -->|getUserIntents| Hook
    OperatorUI -->|getAllPending| Hook
    
    style Hook fill:#ff9800,stroke:#e65100,stroke-width:3px
    style Router fill:#2196f3,stroke:#1565c0,stroke-width:2px
    style PM fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style Operator fill:#9c27b0,stroke:#6a1b9a,stroke-width:2px
```

---

## 2. Instant Swap Flow (Sync Mode)

```mermaid
sequenceDiagram
    participant User
    participant Router as RecorrRouter
    participant PM as PoolManager
    participant Hook as RecorrHook
    participant Pool as USDC/BOB Pool

    User->>Router: swap(100 USDC → BOB, hookData=empty)
    Router->>Router: Approve tokens
    Router->>PM: swap(poolKey, swapParams, hookData)
    Note over Router,PM: PoolManager is the entry point for v4 swaps
    
    PM->>Hook: beforeSwap(hookData)
    
    alt hookData is empty (Instant Mode)
        Hook->>Hook: Check if hookData.length == 0
        Hook-->>PM: return ZERO_DELTA (continue swap)
    end
    
    PM->>Pool: Execute AMM swap
    Pool->>Pool: Calculate output
    Pool-->>PM: Return delta
    
    PM->>Hook: afterSwap(delta)
    Hook->>Hook: Update netFlow (USDC +100)
    Hook->>Hook: Record fee adjustment for next swap
    Hook-->>PM: Return fee adjustment
    Note over Hook,PM: Dynamic fee applies to subsequent swaps
    
    PM-->>Router: Return swap result
    Router-->>User: Transfer output tokens
    
    Note over User,Pool: Instant swap completed in 1 transaction
```

---

## 3. Async Intent + CoW Matching Flow

### PoC Implementation (Current)

```mermaid
sequenceDiagram
    participant UserA as User A (Sell USDC)
    participant UserB as User B (Sell BOB)
    participant Router as RecorrRouter
    participant Hook as RecorrHook
    participant Operator as Settler/Operator
    participant PM as PoolManager

    rect rgba(95, 112, 129, 1)
    Note over UserA,Hook: Phase 1: Intent Creation (PoC: swap still executes)
    UserA->>Router: swap(1000 USDC, hookData=async)
    Router->>PM: swap call
    PM->>Hook: beforeSwap(hookData with minOut + deadline)
    Hook->>Hook: intentId = nextIntentId++ (e.g., #42)
    Hook->>Hook: Store Intent #42 (status=Pending)
    Hook->>Hook: Emit IntentCreated(#42, userA, ...)
    Hook-->>PM: ZERO_DELTA (swap continues - v4 limitation)
    Note over Hook,PM: In current PoC, swap executes normally<br/>Intent is recorded for coordination layer
    PM-->>Router: Swap result
    Router-->>UserA: Intent #42 created + swap executed
    
    UserB->>Router: swap(7000 BOB, hookData=async)
    Router->>PM: swap call
    PM->>Hook: beforeSwap(hookData)
    Hook->>Hook: intentId = nextIntentId++ (e.g., #43)
    Hook->>Hook: Store Intent #43 (status=Pending)
    Hook->>Hook: Emit IntentCreated(#43, userB, ...)
    Hook-->>PM: ZERO_DELTA
    PM-->>Router: Swap result
    Router-->>UserB: Intent #43 created + swap executed
    end

    rect rgba(98, 129, 98, 1)
    Note over Operator,Hook: Phase 2: CoW Matching (Off-Chain)
    Hook->>Operator: IntentCreated events
    Operator->>Operator: Scan pending intents (#42, #43)
    Operator->>Operator: Detect opposing flows:<br/>1000 USDC → BOB vs 7000 BOB → USDC
    Operator->>Operator: Calculate CoW match:<br/>min(1000, 7000/7) = 1000 USDC matched
    Operator->>Operator: Net to AMM: 0 USDC, 0 BOB (perfect match)
    end

    rect rgba(131, 118, 106, 1)
    Note over Operator,PM: Phase 3: Batch Settlement (On-Chain)
    Operator->>Hook: settleBatch([#42, #43])
    Hook->>Hook: Validate intents (Pending, not expired)
    Hook->>Hook: Calculate total buy/sell per side
    Hook->>Hook: CoW matching: 1000 USDC ↔ 7000 BOB
    Hook->>Hook: Net to AMM: 0 (fully matched)
    
    alt Net flow > 0
        Hook->>PM: Execute residual swap in AMM
        PM-->>Hook: Return swap result
    else Perfect match (net = 0)
        Hook->>Hook: No AMM interaction needed
    end
    
    Hook->>Hook: Mark Intent #42 as Executed
    Hook->>Hook: Mark Intent #43 as Executed
    Hook->>Hook: Emit IntentExecuted(#42, 7000)
    Hook->>Hook: Emit IntentExecuted(#43, 1000)
    Hook-->>Operator: Settlement successful
    end

    Note over UserA,UserB: Both users benefit from CoW matching
```

### Production Design (Roadmap)

```mermaid
sequenceDiagram
    participant User
    participant Router as RecorrRouter
    participant Hook as RecorrHook
    participant Operator

    Note over User,Hook: Production: Router.createIntent() - no swap execution
    User->>Router: createIntent(1000 USDC, minOut, deadline)
    Router->>Hook: createIntent() - direct call, no PoolManager.swap
    Hook->>Hook: Store intent
    Hook->>Hook: Emit IntentCreated
    Hook-->>Router: Intent ID
    Router-->>User: Intent created (no swap executed)
    
    Note over Operator: Operator monitors and settles later
    Operator->>Hook: settleBatch([intentIds])
    Hook->>Hook: Execute CoW matching + residual AMM swap if needed
```

---

## 4. CoW Visual - AMM vs CoW Comparison

```mermaid
graph LR
    subgraph "Traditional AMM (Without CoW)"
        A1[User A: Sell USDC] -->|Swap| AMM1[AMM Pool]
        AMM1 -->|Output + slippage| A1
        
        B1[User B: Sell BOB] -->|Swap| AMM2[AMM Pool]
        AMM2 -->|Output + slippage| B1
        
        AMM1 -.->|IL Risk| LP1[LP impacted by<br/>directional flow]
        AMM2 -.->|IL Risk| LP1
    end

    subgraph "RecorrHook CoW Matching"
        A2[User A: Sell USDC] -->|Intent| CoW[CoW Matching Engine]
        B2[User B: Sell BOB] -->|Intent| CoW
        
        CoW -->|Direct Match<br/>0% slippage on matched| A2
        CoW -->|Direct Match<br/>0% slippage on matched| B2
        CoW -->|Output BOB| A2
        CoW -->|Output USDC| B2
        
        CoW -.->|Net flow = 0| AMM3[AMM Pool]
        AMM3 -.->|No IL<br/>Balanced| LP2[LP protected]
    end

    style AMM1 fill:#ff5252,stroke:#c62828,stroke-width:2px
    style AMM2 fill:#ff5252,stroke:#c62828,stroke-width:2px
    style CoW fill:#4caf50,stroke:#2e7d32,stroke-width:3px
    style LP2 fill:#8bc34a,stroke:#558b2f,stroke-width:2px
    style LP1 fill:#ff9800,stroke:#e65100,stroke-width:2px
```

---

## 5. Dynamic Fee Mechanism

```mermaid
graph TD
    subgraph "Fee Calculation Flow"
        Swap[New Swap: 1000 USDC → BOB]
        Check{Direction?}
        
        Swap --> Check
        
        Check -->|zeroForOne = true<br/>USDC → BOB| UpdateZero[netFlow += 1000]
        Check -->|zeroForOne = false<br/>BOB → USDC| UpdateOne[netFlow -= equivalent]
        
        UpdateZero --> CalcFee[Calculate Fee]
        UpdateOne --> CalcFee
        
        CalcFee --> CheckThreshold{abs netFlow > 10k?}
        
        CheckThreshold -->|No| BaseFee[Base Fee: 0.05%]
        CheckThreshold -->|Yes| DynamicFee[Dynamic Fee:<br/>0.05% + up to 0.2%]
        
        DynamicFee --> Formula["fee = baseFee +<br/> extraFee * abs(netFlow) / threshold<br/> capped at maxExtraFee"]
        
        BaseFee --> Apply[Apply Fee to Swap]
        Formula --> Apply
    end

    subgraph "Example"
        Ex1[netFlow = 0<br/>Fee = 0.05%]
        Ex2[netFlow = 10,000<br/>Fee = 0.15%]
        Ex3[netFlow = 20,000+<br/>Fee = 0.25% max]
    end

    style DynamicFee fill:#ff9800,stroke:#e65100,stroke-width:2px
    style BaseFee fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style Formula fill:#2196f3,stroke:#1565c0,stroke-width:2px
```

**Formula:**
```
extraFee = min(maxExtraFee, (abs(netFlow) * maxExtraFee) / netFlowThreshold)
finalFee = baseFee + extraFee

Where:
- baseFee = 500 (0.05%)
- maxExtraFee = 2000 (0.2%)
- netFlowThreshold = 10,000 tokens
- Max total fee = 2500 (0.25%)
```

---

## 6. Cross-Chain Flow (Future Enhancement)

```mermaid
sequenceDiagram
    participant User as User (USA)
    participant Router as RecorrRouter
    participant Hook as RecorrHook
    participant Bridge as MockBridge
    participant ChainB as Destination Chain (Bolivia)
    participant Recipient as Recipient (Bolivia)

    User->>Router: swapAndBridge(1000 USDC → BOB, destChain, recipient)
    Router->>Hook: Create async intent or instant swap
    
    alt Instant Swap
        Hook->>Hook: Execute swap in AMM
    else Async Intent
        Hook->>Hook: Create intent, wait for CoW match
        Note over Hook: Operator settles batch later
    end
    
    Hook-->>Router: Swap executed (7000 BOB)
    Router->>Bridge: bridgeTokens(7000 BOB, destChain, recipient)
    Bridge->>Bridge: Emit BridgeRequested event
    Bridge-->>Router: Bridge initiated
    
    Note over Bridge,ChainB: Off-chain relayers process bridge
    
    Bridge->>ChainB: Cross-chain message
    ChainB->>Recipient: Mint/unlock tokens
    
    Note over User,Recipient: Cross-border remittance completed<br/>Lower fees via CoW + Dynamic pricing
```

---

## 7. Use Cases Diagram

```mermaid
mindmap
  root((RecorrHook<br/>Use Cases))
    Cross-Border Remittances
      USA → Bolivia
      Direct P2P matching
      Lower fees than Western Union
    DeFi Corridor Pools
      USDC ↔ Local Stables
      Reduced IL for LPs
      Better pricing for traders
    Intent-Based Trading
      Limit orders on Uniswap v4
      Gas-efficient batching
      No front-running
    Dynamic Fee Protection
      LP protection from one-way flows
      Fee increases with imbalance
      Incentivizes balancing flows
    Future: Multi-Chain Corridors
      Cross-chain CoW matching
      Bridge optimization
      Global liquidity aggregation
```

---

## 8. Security & Access Control

```mermaid
graph TB
    subgraph "Access Control Hierarchy"
        Owner[Owner<br/>0x7bDa...4BB3]
        Hook[RecorrHook Contract]
        PM[PoolManager<br/>Only authorized caller]
        Users[Regular Users]
        Operator[Settler/Operator<br/>Anyone can call]
        
        Owner -->|setCorridorPool| Hook
        Owner -->|setPoolFeeParams| Hook
        Owner -->|resetNetFlow| Hook
        
        PM -->|beforeSwap| Hook
        PM -->|afterSwap| Hook
        
        Users -->|via Router| PM
        
        Operator -->|settleBatch| Hook
        Operator -->|executeIntent| Hook
    end

    subgraph "Safety Mechanisms"
        NoTokens[No token custody<br/>in Hook]
        BestEffort[Best-effort validation<br/>Never revert batch]
        NoApprovals[No approvals needed<br/>for Hook]
        PMOnly[Only PoolManager<br/>can call hooks]
    end

    subgraph "Intent Validation"
        Check1{Intent exists?}
        Check2{Status = Pending?}
        Check3{Not expired?}
        Check4{Valid amounts?}
        
        Check1 -->|Yes| Check2
        Check2 -->|Yes| Check3
        Check3 -->|Yes| Check4
        Check4 -->|Yes| Execute[Execute/Settle]
        
        Check1 -->|No| Skip[Skip silently]
        Check2 -->|No| Skip
        Check3 -->|No| Skip
        Check4 -->|No| Skip
    end

    style Owner fill:#9c27b0,stroke:#6a1b9a,stroke-width:2px
    style NoTokens fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style Execute fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style Skip fill:#ff9800,stroke:#e65100,stroke-width:2px
```

---

## 9. Performance Metrics

```mermaid
graph LR
    subgraph "Traditional AMM"
        T1[Slippage on each trade]
        T2[Gas per individual swap]
        T3[LP IL: High on unbalanced flows]
        T4[Fees: Fixed]
    end

    subgraph "RecorrHook CoW"
        R1[Slippage: 0% on matched portion]
        R2[Gas: Amortized via batching]
        R3[LP IL: Protected by dynamic fees]
        R4[Fees: 0.05-0.25% dynamic]
    end

    subgraph "Improvements"
        I1[Better prices on matched trades]
        I2[Lower gas via batch settlement]
        I3[Better LP returns in corridors]
        I4[Fair pricing based on flow direction]
    end

    T1 -.->|vs| R1
    T2 -.->|vs| R2
    T3 -.->|vs| R3
    T4 -.->|vs| R4

    R1 --> I1
    R2 --> I2
    R3 --> I3
    R4 --> I4

    style I1 fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style I2 fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style I3 fill:#4caf50,stroke:#2e7d32,stroke-width:2px
    style I4 fill:#4caf50,stroke:#2e7d32,stroke-width:2px
```

---

## 10. Testing Coverage

```mermaid
graph TB
    subgraph "Test Suite"
        Unit[Unit Tests]
        Integration[Integration Tests]
        E2E[End-to-End Tests]
        
        Unit --> T1[Intent Creation]
        Unit --> T2[CoW Matching Logic]
        Unit --> T3[Dynamic Fees]
        Unit --> T4[Access Control]
        
        Integration --> T5[Instant Swaps]
        Integration --> T6[Async Intents]
        Integration --> T7[Batch Settlement]
        Integration --> T8[Pool Initialization]
        
        E2E --> T9[Full CoW Demo]
        E2E --> T10[Cross-Chain Flow Mock]
        E2E --> T11[Multi-User Scenarios]
    end

    subgraph "Coverage Areas"
        C1[Happy paths]
        C2[Edge cases: expire, invalid]
        C3[Security: owner-only]
        C4[Gas optimization]
        C5[Revert scenarios]
    end

    T1 --> C1
    T2 --> C1
    T7 --> C2
    T4 --> C3
    T6 --> C4
    T5 --> C5

    style Unit fill:#2196f3,stroke:#1565c0,stroke-width:2px
    style Integration fill:#ff9800,stroke:#e65100,stroke-width:2px
    style E2E fill:#9c27b0,stroke:#6a1b9a,stroke-width:2px
```

---

## 11. Deployment Architecture

```mermaid
graph TB
    subgraph "Sepolia Testnet Deployment"
        Deploy[DeployRecorrHook.s.sol]
        
        Deploy -->|1. Deploy| MockTokens[MockUSDC + MockBOB]
        Deploy -->|2. Deploy| MockBridge[MockBridge]
        Deploy -->|3. Mine Address| HookAddress[Hook Address Mining<br/>flags: 0x4080]
        Deploy -->|4. Deploy| Hook[RecorrHook<br/>0xfD29...80c0]
        Deploy -->|5. Deploy| Router[RecorrRouter<br/>0xA1ee...CBf2]
        Deploy -->|6. Initialize| Pool[USDC/BOB Pool]
        Deploy -->|7. Add Liquidity| Pool
        
        MockTokens -->|Faucet| Users[Public faucet function]
        Hook -->|Associated with| Pool
        Router -->|Interacts with| Hook
        Router -->|Uses| MockBridge
    end

    subgraph "Contract Addresses"
        A1[MockUSDC: 0x9aD2...9b]
        A2[MockBOB: 0xE58D...6D]
        A3[MockBridge: 0x0612...20e8]
        A4[RecorrHook: 0xfD29...80c0]
        A5[RecorrRouter: 0xA1ee...CBf2]
        A6[Pool ID: 0x3aa9...45f3]
    end

    subgraph "Verification Status"
        V1[All contracts deployed]
        V2[Pool initialized with liquidity]
        V3[Hook permissions verified]
        V4[Etherscan verification pending]
    end

    style Hook fill:#ff9800,stroke:#e65100,stroke-width:3px
    style Router fill:#2196f3,stroke:#1565c0,stroke-width:2px
    style Pool fill:#4caf50,stroke:#2e7d32,stroke-width:2px
```

---

## Notes

- These diagrams are optimized for the Hookathon submission and pitch deck

---

*Generated for RecorrHook Hookathon Submission - December 11, 2025*
