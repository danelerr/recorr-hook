# RecorrHook - Contratos Desplegados en Sepolia

**Fecha de Deployment:** 11 de Diciembre, 2025  
**Network:** Ethereum Sepolia Testnet  
**Chain ID:** 11155111  
**Deployer:** `0x7bDaCFe089dB39fAE6fA57C213EE9811f4C54BB3`

---

## Direcciones de Contratos

### Core Contracts

#### RecorrHook
- **Address:** `0xfD2984eFe82c1291BAeec241A7D47ef0b87F80c0`
- **Type:** Uniswap v4 Hook (BeforeSwap + AfterSwap)
- **Etherscan:** https://sepolia.etherscan.io/address/0xfD2984eFe82c1291BAeec241A7D47ef0b87F80c0
- **Description:** Hook principal que implementa:
  - **Async Intents**: Permite a usuarios crear órdenes límite sin gas por adelantado
  - **CoW Matching**: Ejecuta coincidencias entre órdenes opuestas off-chain
  - **Dynamic Fees**: Ajusta fees dinámicamente según el flujo neto de la pool
  - **Corridor Pools**: Soporte para pools específicas USDC↔BOB para remesas
- **Owner:** `0x7bDaCFe089dB39fAE6fA57C213EE9811f4C54BB3`
- **Hook Permissions:**
  - `beforeSwap`: Enabled
  - `afterSwap`: Enabled

#### RecorrRouter
- **Address:** `0xA1ee6ACBF604e5c165129694340a9124417DCBf2`
- **Type:** Router Contract
- **Etherscan:** https://sepolia.etherscan.io/address/0xA1ee6ACBF604e5c165129694340a9124417DCBf2
- **Description:** Router que facilita interacciones con el hook:
  - Maneja swaps instantáneos
  - Crea async intents
  - Integra con el bridge para flujos cross-chain
  - Simplifica aprobaciones y llamadas al PoolManager
- **Bridge Configurado:** `0x0612A5b0917889000447070849bE035291CA20e8`

---

### Mock Tokens (Testnet)

#### MockUSDC
- **Address:** `0x9aD20ACF1E3592efF473B510603f5f647994cE9b`
- **Symbol:** USDC
- **Decimals:** 6
- **Etherscan:** https://sepolia.etherscan.io/address/0x9aD20ACF1E3592efF473B510603f5f647994cE9b
- **Description:** Token mock que simula USDC para testing
- **Supply Inicial:** 1,000,000 USDC (al deployer)
- **Funciones Públicas:**
  - `faucet()`: Cualquiera puede mintear 10,000 USDC
  - `mintStandard(address to)`: Mintea 10,000 USDC a una dirección
  - `mint(address to, uint256 amount)`: Mintea cantidad específica

#### MockBOB
- **Address:** `0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D`
- **Symbol:** BOB
- **Decimals:** 6
- **Etherscan:** https://sepolia.etherscan.io/address/0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D
- **Description:** Token mock que simula BOB (moneda de Bolivia) para testing
- **Supply Inicial:** 1,000,000 BOB (al deployer)
- **Funciones Públicas:**
  - `faucet()`: Cualquiera puede mintear 10,000 BOB
  - `mintStandard(address to)`: Mintea 10,000 BOB a una dirección
  - `mint(address to, uint256 amount)`: Mintea cantidad específica

---

### Bridge Contract

#### MockBridge
- **Address:** `0x0612A5b0917889000447070849bE035291CA20e8`
- **Type:** Cross-Chain Bridge Mock
- **Etherscan:** https://sepolia.etherscan.io/address/0x0612A5b0917889000447070849bE035291CA20e8
- **Description:** Mock bridge que simula transferencias cross-chain
- **Funcionalidad:**
  - Emite eventos de bridge para testing
  - Permite simular flujos de remesas cross-chain
  - Integrado con RecorrRouter para flujos completos

---

## Pool Information

### USDC/BOB Pool
- **Pool ID:** `0x3aa9f240666b603b79bd9f409b58b326b30e308c6792065411d368509de145f3`
- **Currency0 (USDC):** `0x9aD20ACF1E3592efF473B510603f5f647994cE9b`
- **Currency1 (BOB):** `0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D`
- **Fee Type:** Dynamic (0x800000)
- **Tick Spacing:** 60
- **Hook:** `0xfD2984eFe82c1291BAeec241A7D47ef0b87F80c0`
- **Initial Price:** ~1:7 (1 USDC ≈ 7 BOB)
- **Liquidity:** Active
- **Status:** Initialized and operational

**Pool Manager (Uniswap v4):**
- **Address:** `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
- **Network:** Sepolia
- **Docs:** https://docs.uniswap.org/contracts/v4/deployments

**Dirección donde "vive" el hook:** El hook vive en la dirección `0xfD2984eFe82c1291BAeec241A7D47ef0b87F80c0`, pero está **asociado** a la pool con ID `0x3aa9f240666b603b79bd9f409b58b326b30e308c6792065411d368509de145f3` dentro del PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`.

---

## Fee Configuration

- **Base Fee:** 500 (0.05%)
- **Max Extra Fee:** 2000 (0.2%)
- **Total Max Fee:** 2500 (0.25%)
- **Net Flow Threshold:** 10,000 tokens
- **Dynamic Adjustment:** Las fees aumentan cuando el flujo neto excede el threshold

---

## Security & Ownership

- **Hook Owner:** `0x7bDaCFe089dB39fAE6fA57C213EE9811f4C54BB3`
- **Router Owner:** Same as deployer
- **Token Owners:** Same as deployer (con funciones públicas de mint para testing)
- **Access Control:** Solo el owner puede:
  - Configurar corridor pools
  - Ajustar parámetros de fees
  - Actualizar configuraciones del hook

---

## Transaction Details

- **Total Gas Used:** 12,640,780 gas
- **Estimated Cost:** 0.00001390518666028 ETH
- **Deployment Script:** `script/DeployRecorrHook.s.sol`
- **Broadcast File:** `/broadcast/DeployRecorrHook.s.sol/11155111/run-latest.json`

---

## Testing & Verification

### Cómo obtener tokens de test:

```solidity
// Opción 1: Faucet directo (sin parámetros)
MockUSDC(0x9aD20ACF1E3592efF473B510603f5f647994cE9b).faucet();
MockBOB(0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D).faucet();

// Opción 2: Mintear a una dirección específica
MockUSDC(0x9aD20ACF1E3592efF473B510603f5f647994cE9b).mintStandard(yourAddress);
MockBOB(0xE58DC0658b462510C3A4A17372528A2C4A1a4E6D).mintStandard(yourAddress);
```

### Contract Verification Status:
- RecorrHook: Pending verification on Etherscan
- RecorrRouter: To be verified
- MockUSDC: To be verified
- MockBOB: To be verified
- MockBridge: To be verified

---

## Hookathon Submission Info

**Project Name:** RecorrHook  
**Category:** Uniswap v4 Hooks  
**Key Features:**
1. Async Intent-Based Trading
2. CoW (Coincidence of Wants) Matching
3. Dynamic Fee Adjustment
4. Cross-Border Remittance Optimization

**Demo Flow:**
1. User A creates intent: Sell USDC for BOB
2. User B creates intent: Sell BOB for USDC
3. Settler executes CoW batch settlement off-chain
4. Both users get better prices + lower fees
5. Dynamic fees adjust based on directional flow

---

## Links & Resources

- **GitHub:** https://github.com/danelerr/recorr-hook
- **Uniswap v4 Docs:** https://docs.uniswap.org/contracts/v4/overview
- **Sepolia Faucet:** https://sepoliafaucet.com
- **Etherscan (Sepolia):** https://sepolia.etherscan.io

---

*Deployment completed on December 11, 2025 for Uniswap Hook Incubator V7 - Hookathon*
