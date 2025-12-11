// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {RecorrHookTypes} from "./RecorrHookTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RecorrHook
 * @notice FX corridor hook for Uniswap v4 enabling async intents, CoW matching, and dynamic fees
 * @dev Implements async swap intents with batch settlement and Coincidence of Wants (CoW) matching
 * 
 * Key Features:
 * - Async intent creation instead of immediate swaps
 * - Batch settlement with peer-to-peer CoW matching
 * - Dynamic corridor fees based on flow imbalance
 * - Designed for stablecoin FX corridors
 * 
 * Architecture:
 * - Phase 1: Basic hook skeleton with corridor pool registry (CURRENT)
 * - Phase 2: Intent creation and storage
 * - Phase 3: Batch settlement v1 (no CoW)
 * - Phase 4: CoW matching and netting
 * - Phase 5: Dynamic fee implementation
 * 
 * IMPORTANT - Design Evolution:
 * Phase 1 (current): BeforeSwapDelta returns ZERO_DELTA
 *   → No balance modifications in beforeSwap, passthrough only
 * 
 * Phase 2+ (async intents): May use non-zero BeforeSwapDelta to handle intent accounting
 *   → Need to REDEPLOY with new mined address that has these permission bits
 *   → The hook address encodes permissions in its bits (Uniswap v4 design)
 * 
 * Phase 5 (dynamic fees): Will use lpFeeOverride with LPFeeLibrary.OVERRIDE_FEE_FLAG
 *   → No address change needed, but ensure pool is initialized with DYNAMIC_FEE_FLAG
 * 
 * @custom:security Follow Uniswap v4 best practices:
 * - All hook callbacks protected with onlyPoolManager
 * - Hook address validated via HookMiner to ensure correct permission bits
 * - Never call PoolManager from within hooks (use external settler contracts)
 */
contract RecorrHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // =============================================================
    //                       STATE VARIABLES
    // =============================================================

    /// @notice Tracks which pools are designated as corridor pools
    mapping(PoolId => bool) public isCorridorPool;

    /// @notice Intent storage by ID
    mapping(uint256 => RecorrHookTypes.Intent) public intents;

    /// @notice Counter for generating unique intent IDs
    uint256 public nextIntentId;

    /// @notice Dynamic fee parameters per pool
    mapping(PoolId => RecorrHookTypes.FeeParams) public poolFeeParams;

    /// @notice Net flow tracking per pool (positive = more zeroForOne, negative = more oneForZero)
    mapping(PoolId => int256) public netFlow;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(
        IPoolManager _poolManager
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        // Validate that this contract was deployed to an address with correct permission bits
        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        nextIntentId = 1; // Start intent IDs at 1
    }

    // =============================================================
    //                     HOOK PERMISSIONS
    // =============================================================

    /**
     * @notice Returns the hook's permissions
     * @dev Specifies which hook functions this contract implements
     * @return Hooks.Permissions struct with enabled hooks
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,           // ✓ We intercept swaps for intent creation
            afterSwap: true,            // ✓ We use afterSwap for fee/flow tracking
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set whether a pool is a corridor pool
     * @dev Only owner can designate corridor pools
     * @param key The pool key
     * @param value True to mark as corridor pool, false otherwise
     */
    function setCorridorPool(PoolKey calldata key, bool value) external onlyOwner {
        require(address(key.hooks) == address(this), "RecorrHook: wrong hook");
        PoolId poolId = key.toId();
        isCorridorPool[poolId] = value;
        emit RecorrHookTypes.CorridorPoolSet(poolId, value);
    }

    /**
     * @notice Set dynamic fee parameters for a corridor pool
     * @dev Only owner can configure fee parameters
     *      Pool must be initialized with DYNAMIC_FEE_FLAG (0x800000) and use this hook
     * @param key The pool key
     * @param params Fee parameters (baseFee, maxExtraFee, netFlowThreshold)
     */
    function setPoolFeeParams(
        PoolKey calldata key,
        RecorrHookTypes.FeeParams calldata params
    ) external onlyOwner {
        PoolId poolId = key.toId();
        
        // Validate that this pool uses this hook
        require(address(key.hooks) == address(this), "RecorrHook: wrong hook");
        
        // Validate that pool has dynamic fee enabled (0x800000 flag)
        require(LPFeeLibrary.isDynamicFee(key.fee), "RecorrHook: pool not dynamic");
        
        // Validate fee parameters using LPFeeLibrary (v4 allows up to 1_000_000 = 100%)
        if (!LPFeeLibrary.isValid(params.baseFee) || !LPFeeLibrary.isValid(params.maxExtraFee)) {
            revert RecorrHookTypes.InvalidFeeParams();
        }
        
        // Additional policy: limit each component to 1% (10000 in basis points)
        // Total dynamic fee can reach up to 2% (baseFee + maxExtraFee)
        if (params.baseFee > 10000 || params.maxExtraFee > 10000) {
            revert RecorrHookTypes.InvalidFeeParams();
        }
        
        poolFeeParams[poolId] = params;
        
        emit RecorrHookTypes.DynamicFeeUpdated(
            poolId,
            params.baseFee,
            params.maxExtraFee,
            params.netFlowThreshold
        );
    }

    // =============================================================
    //                       HOOK FUNCTIONS
    // =============================================================

    /**
     * @notice Internal implementation of beforeSwap hook
     * @dev Phase 2: Creates async intents when hookData signals async mode
     *      Phase 5: Applies dynamic fees based on netFlow imbalance
     * @param key The pool key
     * @param params Swap parameters
     * @param hookData Encoded mode: 0x01 = async intent, 0x00 = immediate swap
     * @return selector The function selector
     * @return delta The balance delta (zero for async, may be non-zero in future phases)
     * @return lpFeeOverride The LP fee override (0 = no override, or dynamic fee)
     */
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // Only process if this is a corridor pool
        if (!isCorridorPool[poolId]) {
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }
        
        // Phase 2: Check if this should be an async intent
        // hookData encoding MUST be:
        //   abi.encodePacked(uint8(0x01), abi.encode(uint256 minOut, uint48 deadline))
        // This produces exactly 65 bytes: 1 byte mode + 64 bytes ABI-encoded params
        if (hookData.length > 0 && hookData[0] == 0x01) {
            // Decode intent parameters from hookData
            require(hookData.length == 1 + 32 + 32, "Invalid hookData length");
            
            // Decode using abi.decode for safety and clarity
            (uint256 minOut, uint48 deadline) = abi.decode(
                hookData[1:], // Skip first byte (mode)
                (uint256, uint48)
            );
            
            // WARNING: Using tx.origin for hackathon / PoC purposes only.
            // In production we would pass the owner address explicitly from the router
            // to avoid any tx.origin-based attacks or limitations.
            // See: https://consensys.github.io/smart-contract-best-practices/development-recommendations/solidity-specific/tx-origin/
            _createIntent(tx.origin, poolId, params, minOut, deadline);
            
            // NOTE: Hackathon / demo behavior:
            // - We CREATE an async intent for analytics / CoW batch settlement
            // - AND we still let the underlying swap execute normally (ZERO_DELTA doesn't cancel in v4)
            //
            // In a production deployment you would:
            // - either only create intents from a dedicated router
            // - or revert here to prevent the swap from executing immediately
            //
            // Current behavior demonstrates the CoW coordination concept while maintaining
            // compatibility with generic routers.
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }
        
        // Phase 5: Calculate dynamic fee based on netFlow
        uint24 lpFeeOverride = _calculateDynamicFee(poolId, params);
        
        // Immediate swap with dynamic fee
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            lpFeeOverride
        );
    }

    /**
     * @notice Internal implementation of afterSwap hook
     * @dev Phase 5: Tracks netFlow to adjust dynamic fees
     * @param key The pool key
     * @param params Swap parameters
     * @param delta The balance delta from the swap
     * @return selector The function selector
     * @return hookDeltaUnspecified The hook's delta (0)
     */
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Only track netFlow for corridor pools
        if (isCorridorPool[poolId]) {
            int256 oldNetFlow = netFlow[poolId];
            
            // Update netFlow based on swap direction and amounts
            // In Uniswap v4: positive delta = user pays, negative delta = user receives
            // Positive netFlow = more zeroForOne swaps, negative = more oneForZero
            int128 amount0 = delta.amount0();
            int128 amount1 = delta.amount1();
            
            if (params.zeroForOne) {
                // zeroForOne: user sells token0, buys token1
                // amount0 is positive (user pays), amount1 is negative (user receives)
                // Track positive netFlow for zeroForOne pressure
                netFlow[poolId] = oldNetFlow + _abs(amount0);
            } else {
                // oneForZero: user sells token1, buys token0
                // amount1 is positive (user pays), amount0 is negative (user receives)
                // Negative contribution to netFlow
                netFlow[poolId] = oldNetFlow - _abs(amount1);
            }
            
            // Emit event if netFlow changed significantly
            if (netFlow[poolId] != oldNetFlow) {
                emit RecorrHookTypes.NetFlowUpdated(poolId, oldNetFlow, netFlow[poolId]);
            }
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get intent details by ID
     * @param intentId The intent ID
     * @return The intent struct
     */
    function getIntent(uint256 intentId) external view returns (RecorrHookTypes.Intent memory) {
        return intents[intentId];
    }
    
    /**
     * @notice Get all intent IDs for a specific user
     * @dev WARNING: O(n) complexity - not scalable for production with many intents.
     *      For mainnet, use off-chain indexing (subgraph, indexer) or maintain
     *      per-user intent lists on-chain. This is a PoC/hackathon convenience function.
     * @param user The user address
     * @param maxResults Maximum number of results to return
     * @return intentIds Array of intent IDs belonging to the user
     */
    function getUserIntents(address user, uint256 maxResults) external view returns (uint256[] memory intentIds) {
        // Count user's intents first
        uint256 count = 0;
        uint256 totalIntents = nextIntentId - 1;
        
        for (uint256 i = 1; i <= totalIntents && count < maxResults; i++) {
            if (intents[i].owner == user) {
                count++;
            }
        }
        
        // Allocate array and populate
        intentIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= totalIntents && index < count; i++) {
            if (intents[i].owner == user) {
                intentIds[index] = i;
                index++;
            }
        }
        
        return intentIds;
    }

    /**
     * @notice Check if a pool is a corridor pool
     * @param key The pool key
     * @return True if the pool is a corridor pool
     */
    function isPoolCorridor(PoolKey calldata key) external view returns (bool) {
        return isCorridorPool[key.toId()];
    }

    /**
     * @notice Get fee parameters for a pool
     * @param key The pool key
     * @return The fee parameters
     */
    function getPoolFeeParams(PoolKey calldata key) external view returns (RecorrHookTypes.FeeParams memory) {
        return poolFeeParams[key.toId()];
    }

    /**
     * @notice Get net flow for a pool
     * @param key The pool key
     * @return The current net flow
     */
    function getNetFlow(PoolKey calldata key) external view returns (int256) {
        return netFlow[key.toId()];
    }

    /**
     * @notice Reset net flow for a corridor pool
     * @dev In production, an operator or AVS could reset netFlow periodically
     *      or use a time-windowed scheme. For the hackathon we use a simple
     *      accumulator to illustrate the dynamic fee logic.
     * @param key The pool key
     */
    function resetNetFlow(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        int256 oldFlow = netFlow[poolId];
        netFlow[poolId] = 0;
        emit RecorrHookTypes.NetFlowUpdated(poolId, oldFlow, 0);
    }

    // =============================================================
    //                   SETTLEMENT FUNCTIONS
    // =============================================================
    
    /**
     * @notice Settle a single intent (Phase 3)
     * @dev Can be called by anyone (solvers) to execute pending intents
     * @param intentId The ID of the intent to settle
     * @param amountOut The actual output amount from the settlement
     */
    function settleIntent(uint256 intentId, uint256 amountOut) external {
        RecorrHookTypes.Intent storage intent = intents[intentId];
        
        if (intent.settled) revert RecorrHookTypes.IntentAlreadySettled(intentId);
        if (intent.deadline < block.timestamp) revert RecorrHookTypes.IntentExpired(intentId, intent.deadline);
        if (amountOut < intent.minOut) revert RecorrHookTypes.MinOutputNotMet(intent.minOut, amountOut);
        
        // Mark as settled
        intent.settled = true;
        
        emit RecorrHookTypes.IntentSettled(intentId, intent.owner, uint256(intent.amountSpecified), amountOut);
        
        // Note: Actual token transfers would happen in an external router/settler
        // The hook only tracks the intent state
    }
    
    /**
     * @notice Batch settle multiple intents with CoW matching (Phase 4)
     * @dev Implements Coincidence of Wants:
     *      1. Groups intents by direction (zeroForOne vs oneForZero)
     *      2. Matches opposing flows peer-to-peer
     *      3. Only sends net difference to AMM
     *      Uses "best-effort" approach: skips invalid intents instead of reverting
     * @param intentIds Array of intent IDs to settle
     * @param amountsOut Array of output amounts (must match intentIds length)
     * @return cowStats Statistics about the CoW execution
     */
    function settleCorridorBatch(
        uint256[] calldata intentIds,
        uint256[] calldata amountsOut
    ) external returns (RecorrHookTypes.CoWStats memory cowStats) {
        require(intentIds.length == amountsOut.length, "Length mismatch");
        require(intentIds.length > 0, "Empty batch");
        
        // Phase 4: CoW matching - aggregate flows by direction
        uint256 totalZeroForOne = 0;
        uint256 totalOneForZero = 0;
        uint256 validIntents = 0;
        PoolId poolIdRef;
        bool hasPoolIdRef = false;
        
        // First pass: validate and aggregate
        for (uint256 i = 0; i < intentIds.length; i++) {
            RecorrHookTypes.Intent storage intent = intents[intentIds[i]];
            
            // Skip non-existent intents
            if (intent.owner == address(0)) {
                continue;
            }
            
            // Skip intents that won't be processed (best-effort)
            if (intent.settled || intent.deadline < block.timestamp) {
                continue;
            }
            
            if (amountsOut[i] < intent.minOut) {
                continue;
            }
            
            // Verify all VALID intents are from the same corridor pool
            if (!hasPoolIdRef) {
                poolIdRef = intent.poolId;
                hasPoolIdRef = true;
                
                // Ensure this is actually a corridor pool
                if (!isCorridorPool[poolIdRef]) {
                    revert RecorrHookTypes.NotCorridorPool(poolIdRef);
                }
            } else {
                require(
                    PoolId.unwrap(intent.poolId) == PoolId.unwrap(poolIdRef),
                    "Mixed pool intents"
                );
            }
            
            // Accumulate by direction
            if (intent.zeroForOne) {
                totalZeroForOne += uint256(intent.amountSpecified);
            } else {
                totalOneForZero += uint256(intent.amountSpecified);
            }
            
            validIntents++;
        }
        
        // Require at least one valid intent
        require(validIntents > 0, "No valid intents");
        
        // Calculate CoW matching
        uint256 matchedAmount = totalZeroForOne < totalOneForZero 
            ? totalZeroForOne 
            : totalOneForZero;
        
        uint256 netAmountToAmm;
        bool netDirection;
        
        if (totalZeroForOne > totalOneForZero) {
            netAmountToAmm = totalZeroForOne - totalOneForZero;
            netDirection = true; // Net flow is zeroForOne
        } else if (totalOneForZero > totalZeroForOne) {
            netAmountToAmm = totalOneForZero - totalZeroForOne;
            netDirection = false; // Net flow is oneForZero
        } else {
            // Perfect match: no net flow, direction is arbitrary (convention: true)
            netAmountToAmm = 0;
            netDirection = true;
        }
        
        // Second pass: mark intents as settled and emit events
        for (uint256 i = 0; i < intentIds.length; i++) {
            RecorrHookTypes.Intent storage intent = intents[intentIds[i]];
            
            // Skip invalid intents (same checks as first pass)
            if (intent.settled || intent.deadline < block.timestamp || amountsOut[i] < intent.minOut) {
                continue;
            }
            
            // Mark as settled
            intent.settled = true;
            
            emit RecorrHookTypes.IntentSettled(
                intentIds[i], 
                intent.owner, 
                uint256(intent.amountSpecified), 
                amountsOut[i]
            );
        }
        
        // Calculate gas savings: each matched swap avoids ~100k gas
        // Formula: matchedAmount represents P2P volume that didn't touch AMM
        uint256 gasSaved = matchedAmount > 0 ? (validIntents * 50000) : 0;
        
        // Build return struct
        cowStats = RecorrHookTypes.CoWStats({
            totalIntents: validIntents,
            totalZeroForOne: totalZeroForOne,
            totalOneForZero: totalOneForZero,
            matchedAmount: matchedAmount,
            netAmountToAmm: netAmountToAmm,
            netDirection: netDirection,
            gasSaved: gasSaved
        });
        
        // Emit CoW event if there was actual matching
        if (validIntents > 1 && matchedAmount > 0) {
            emit RecorrHookTypes.CoWExecuted(
                cowStats.totalIntents,
                cowStats.matchedAmount,
                cowStats.netAmountToAmm,
                cowStats.netDirection,
                cowStats.gasSaved
            );
        }
        
        return cowStats;
    }
    
    // =============================================================
    //                    INTERNAL HELPERS
    // =============================================================
    
    /**
     * @notice Helper to get absolute value of int128
     * @param x The signed integer
     * @return The absolute value as int256
     */
    function _abs(int128 x) private pure returns (int256) {
        return x >= 0 ? int256(x) : -int256(x);
    }
    
    /**
     * @notice Create an async intent for later settlement
     * @dev Phase 2 implementation - stores intent on-chain
     * @param owner The user creating the intent
     * @param poolId The pool ID
     * @param params The swap parameters
     * @param minOut Minimum output amount (slippage protection)
     * @param deadline Intent expiration timestamp
     */
    function _createIntent(
        address owner,
        PoolId poolId,
        SwapParams calldata params,
        uint256 minOut,
        uint48 deadline
    ) internal {
        if (deadline <= block.timestamp) revert RecorrHookTypes.InvalidDeadline(deadline);
        if (minOut == 0) revert RecorrHookTypes.ZeroAmount();
        
        // Convert amountSpecified to absolute value (intent notional amount)
        uint256 absAmount = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
        if (absAmount == 0) revert RecorrHookTypes.ZeroAmount();
        if (absAmount > type(uint128).max) revert RecorrHookTypes.AmountTooLarge();
        
        uint256 intentId = nextIntentId++;
        
        intents[intentId] = RecorrHookTypes.Intent({
            owner: owner,
            zeroForOne: params.zeroForOne,
            amountSpecified: uint128(absAmount),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            minOut: minOut,
            deadline: deadline,
            settled: false,
            poolId: poolId
        });
        
        emit RecorrHookTypes.IntentCreated(
            intentId,
            owner,
            poolId,
            params.zeroForOne,
            uint128(absAmount),
            minOut,
            deadline
        );
    }
    
    /**
     * @notice Calculate dynamic fee based on net flow imbalance
     * @dev Phase 5: Linear fee increase when netFlow exceeds threshold
     *      Uses LPFeeLibrary.OVERRIDE_FEE_FLAG to signal dynamic fee
     *      Only used for pools with DYNAMIC_FEE_FLAG enabled
     * @param poolId The pool ID
     * @return lpFeeOverride The calculated fee with OVERRIDE_FEE_FLAG, or 0 if no override
     */
    function _calculateDynamicFee(
        PoolId poolId,
        SwapParams calldata /* params */
    ) internal view returns (uint24) {
        RecorrHookTypes.FeeParams memory feeParams = poolFeeParams[poolId];
        
        // If no fee params configured, no override
        if (feeParams.baseFee == 0) {
            return 0;
        }
        
        int256 currentNetFlow = netFlow[poolId];
        uint24 dynamicFee = feeParams.baseFee;
        
        // Calculate extra fee based on netFlow imbalance
        if (feeParams.netFlowThreshold > 0) {
            int256 absNetFlow = currentNetFlow >= 0 ? currentNetFlow : -currentNetFlow;
            
            if (absNetFlow > feeParams.netFlowThreshold) {
                // Linear increase: extraFee proportional to how much we exceed threshold
                // excessRatio is in basis points (10_000 = 100%)
                uint256 excessRatio = uint256(absNetFlow - feeParams.netFlowThreshold) * 10_000 
                    / uint256(feeParams.netFlowThreshold);
                
                uint24 extraFee = uint24((uint256(feeParams.maxExtraFee) * excessRatio) / 10_000);
                
                // Cap at maxExtraFee
                if (extraFee > feeParams.maxExtraFee) {
                    extraFee = feeParams.maxExtraFee;
                }
                
                dynamicFee += extraFee;
            }
        }
        
        // Validate fee is within v4 bounds
        LPFeeLibrary.validate(dynamicFee);
        
        // Return with OVERRIDE_FEE_FLAG (0x400000) set
        return dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}
