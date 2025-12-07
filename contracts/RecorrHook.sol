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
 * IMPORTANT - Permission Migration:
 * Phase 1 (current): beforeSwapReturnDelta = false, afterSwapReturnDelta = false
 *   → No balance modifications, passthrough only
 * 
 * Phase 2+ (async intents): Will require beforeSwapReturnDelta = true
 *   → Need to REDEPLOY with new mined address that has these permission bits
 *   → The hook address encodes permissions in its bits (Uniswap v4 design)
 * 
 * Phase 5 (dynamic fees): Will use lpFeeOverride with LPFeeLibrary.OVERRIDE_FEE_FLAG
 *   → No address change needed, but ensure pool is initialized with DYNAMIC_FEE_FLAG
 * 
 * @custom:security Follow Uniswap v4 best practices:
 * - All hook callbacks protected with onlyPoolManager
 * - Hook address validated against permissions in constructor
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
        
        // Additional policy: limit to 10000 (1%) for our corridor use case
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
     * @dev Phase 1: Simple passthrough with logging
     *      Phase 2+: Will implement intent creation logic
     * @param key The pool key
     * @return selector The function selector
     * @return delta The balance delta (Phase 1: zero, Phase 2+: may be non-zero for intents)
     * @return lpFeeOverride The LP fee override (0 = no override)
     */
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        bytes calldata /* hookData */
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
        
        // Phase 1: Passthrough for corridor pools
        // TODO Phase 2: Parse hookData to determine if this should be async
        // TODO Phase 2: If async, create intent and return early
        // TODO Phase 5: Calculate and apply dynamic fees using _calculateDynamicFee
        
        // For now, just pass through with no modifications
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0  // No LP fee override
        );
    }

    /**
     * @notice Internal implementation of afterSwap hook
     * @dev Used for tracking netFlow and updating metrics
     * @param key The pool key
     * @return selector The function selector
     * @return hookDeltaUnspecified The hook's delta (Phase 1: 0)
     */
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Only track netFlow for corridor pools
        if (isCorridorPool[poolId]) {
            // Phase 1: No netFlow tracking yet
            // TODO Phase 5: Update netFlow based on params.zeroForOne and delta
            // int256 oldNet = netFlow[poolId];
            // ... calculate netFlow change based on delta ...
            // emit RecorrHookTypes.NetFlowUpdated(poolId, oldNet, netFlow[poolId]);
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

    // =============================================================
    //                   SETTLEMENT FUNCTIONS
    // =============================================================
    
    // TODO Phase 3: Implement settleCorridorBatch(uint256[] calldata intentIds)
    // TODO Phase 4: Add CoW matching logic to settlement
    
    // =============================================================
    //                    INTERNAL HELPERS
    // =============================================================
    
    // TODO Phase 2: Implement _createIntent()
    // TODO Phase 3: Implement _settleIntent()
    // TODO Phase 4: Implement _calculateCoW()
    
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
