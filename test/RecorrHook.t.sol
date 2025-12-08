// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {RecorrHook} from "../contracts/RecorrHook.sol";
import {RecorrHookTypes} from "../contracts/RecorrHookTypes.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/**
 * @title RecorrHookTest
 * @notice Test suite for RecorrHook (Phases 1-3 + netFlow tracking for Phase 5)
 * @dev Tests corridor registry, async intents, settlement, and dynamic fee infrastructure
 */
contract RecorrHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    RecorrHook hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // Deploy v4-core contracts
        deployFreshManagerAndRouters();
        
        // Deploy and approve currencies
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Calculate hook permission flags (Phase 1: only beforeSwap + afterSwap)
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // Mine hook address with correct permission bits using CREATE2
        bytes memory constructorArgs = abi.encode(address(manager));
        (address expectedHookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(RecorrHook).creationCode,
            constructorArgs
        );

        // Deploy hook with the mined salt
        hook = new RecorrHook{salt: salt}(IPoolManager(address(manager)));
        
        // Verify address matches (critical for permission validation)
        assertEq(address(hook), expectedHookAddress, "hook address mismatch");

        // Create a test pool key with DYNAMIC_FEE_FLAG for dynamic fee support
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // 0x800000 - enables dynamic fees
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Initialize the pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    // =============================================================
    //                  PHASE 1: BASIC TESTS
    // =============================================================

    function test_ConstructorSetsOwner() public view {
        assertEq(hook.owner(), address(this));
    }

    function test_HookPermissionsAreCorrect() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap, "beforeSwap should be enabled");
        assertTrue(permissions.afterSwap, "afterSwap should be enabled");
        assertFalse(permissions.beforeInitialize, "beforeInitialize should be disabled");
    }

    function test_SetCorridorPool() public {
        // Initially not a corridor pool
        assertFalse(hook.isCorridorPool(poolId));

        // Set as corridor pool
        hook.setCorridorPool(poolKey, true);
        assertTrue(hook.isCorridorPool(poolId));

        // Unset
        hook.setCorridorPool(poolKey, false);
        assertFalse(hook.isCorridorPool(poolId));
    }

    function test_SetCorridorPoolRevertsForNonOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.setCorridorPool(poolKey, true);
    }

    function test_SetPoolFeeParams() public {
        RecorrHookTypes.FeeParams memory params = RecorrHookTypes.FeeParams({
            baseFee: 500,           // 5 bps
            maxExtraFee: 1000,      // 10 bps
            netFlowThreshold: 1e18  // 1 token threshold
        });

        hook.setPoolFeeParams(poolKey, params);

        RecorrHookTypes.FeeParams memory storedParams = hook.getPoolFeeParams(poolKey);
        assertEq(storedParams.baseFee, 500);
        assertEq(storedParams.maxExtraFee, 1000);
        assertEq(storedParams.netFlowThreshold, 1e18);
    }

    function test_SetPoolFeeParamsRevertsForInvalidParams() public {
        RecorrHookTypes.FeeParams memory invalidParams = RecorrHookTypes.FeeParams({
            baseFee: 20000,         // Too high (> 10000)
            maxExtraFee: 1000,
            netFlowThreshold: 1e18
        });

        vm.expectRevert(RecorrHookTypes.InvalidFeeParams.selector);
        hook.setPoolFeeParams(poolKey, invalidParams);
    }

    function test_SwapPassesThrough() public {
        // Set as corridor pool
        hook.setCorridorPool(poolKey, true);

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Execute a swap
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // Exact input of 1 token

        // Should not revert - swap passes through
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function test_NextIntentIdStartsAtOne() public view {
        assertEq(hook.nextIntentId(), 1);
    }

    function test_ViewFunctionsWork() public {
        // Test isPoolCorridor
        assertFalse(hook.isPoolCorridor(poolKey));
        hook.setCorridorPool(poolKey, true);
        assertTrue(hook.isPoolCorridor(poolKey));

        // Test getNetFlow (should be 0 initially)
        assertEq(hook.getNetFlow(poolKey), 0);
    }
    
    // =============================================================
    //                    PHASE 2 TESTS (ASYNC INTENTS)
    // =============================================================
    
    function test_CreateAsyncIntent() public {
        // Set up corridor pool
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Encode async hookData: [0x01][minOut:uint256][deadline:uint48]
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Encode as [0x01][abi.encode(minOut, deadline)]
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // Small amount to avoid price limit issues
        
        // Execute swap with async hookData
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        
        // Verify intent was created
        RecorrHookTypes.Intent memory intent = hook.getIntent(1);
        // Note: owner is tx.origin (DEFAULT_SENDER in Foundry tests)
        assertEq(intent.owner, tx.origin, "Intent owner incorrect");
        assertTrue(intent.zeroForOne, "Intent direction incorrect");
        assertEq(intent.amountSpecified, 1e18, "Intent amount incorrect");
        assertEq(intent.minOut, minOut, "Intent minOut incorrect");
        assertEq(intent.deadline, deadline, "Intent deadline incorrect");
        assertFalse(intent.settled, "Intent should not be settled");
    }
    
    function test_AsyncIntentIncrementsId() public {
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool (increased to 100 ether for multiple swaps)
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Use abi.encode for proper ABI alignment (not encodePacked)
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -0.1e18; // Reduced to avoid hitting MIN_PRICE_LIMIT
        
        // NOTE: Removed initial "normal swap" - it pushes price to MIN_PRICE_LIMIT,
        // causing subsequent swaps to fail with PriceLimitAlreadyExceeded.
        // swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Create first intent
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        RecorrHookTypes.Intent memory intent1 = hook.getIntent(1);
        assertEq(intent1.owner, tx.origin, "First intent owner incorrect");
        
        // Create second intent
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        RecorrHookTypes.Intent memory intent2 = hook.getIntent(2);
        assertEq(intent2.owner, tx.origin, "Second intent owner incorrect");
        
        // Verify IDs incremented
        assertEq(intent1.amountSpecified, intent2.amountSpecified, "Intents should have same amount");
    }
    
    function test_GetUserIntents() public {
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Use abi.encode for proper ABI alignment (not encodePacked)
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -0.1e18; // Reduced to avoid hitting MIN_PRICE_LIMIT
        
        // NOTE: Removed initial "normal swap" - it pushes price to MIN_PRICE_LIMIT,
        // causing subsequent swaps to fail with PriceLimitAlreadyExceeded.
        // swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Create 3 intents
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        
        // Get user intents (tx.origin is the owner in Foundry tests)
        uint256[] memory intentIds = hook.getUserIntents(tx.origin, 10);
        assertEq(intentIds.length, 3, "Should have 3 intents");
        assertEq(intentIds[0], 1, "First intent ID should be 1");
        assertEq(intentIds[1], 2, "Second intent ID should be 2");
        assertEq(intentIds[2], 3, "Third intent ID should be 3");
    }
    
    // =============================================================
    //                    PHASE 3 TESTS (SETTLEMENT)
    // =============================================================
    
    function test_SettleIntent() public {
        // Create an intent first
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Encode as [0x01][abi.encode(minOut, deadline)]
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        
        // Settle the intent
        uint256 actualOut = 96e18;
        hook.settleIntent(1, actualOut);
        
        // Verify intent is settled
        RecorrHookTypes.Intent memory intent = hook.getIntent(1);
        assertTrue(intent.settled, "Intent should be settled");
    }
    
    function test_SettleBatch() public {
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Use abi.encode for proper ABI alignment (not encodePacked)
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -0.1e18; // Reduced to avoid hitting MIN_PRICE_LIMIT
        
        // NOTE: Removed initial "normal swap" - it pushes price to MIN_PRICE_LIMIT,
        // causing subsequent swaps to fail with PriceLimitAlreadyExceeded.
        // swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Create 3 intents
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        
        // Batch settle
        uint256[] memory intentIds = new uint256[](3);
        intentIds[0] = 1;
        intentIds[1] = 2;
        intentIds[2] = 3;
        
        uint256[] memory amountsOut = new uint256[](3);
        amountsOut[0] = 96e18;
        amountsOut[1] = 97e18;
        amountsOut[2] = 98e18;
        
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify all settled
        assertTrue(hook.getIntent(1).settled, "Intent 1 should be settled");
        assertTrue(hook.getIntent(2).settled, "Intent 2 should be settled");
        assertTrue(hook.getIntent(3).settled, "Intent 3 should be settled");
    }
    
    function test_RevertIfSettleExpiredIntent() public {
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Encode as [0x01][abi.encode(minOut, deadline)]
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // Small amount to avoid price limit issues
        
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        
        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);
        
        // Try to settle - should revert with custom error
        vm.expectRevert(
            abi.encodeWithSelector(
                RecorrHookTypes.IntentExpired.selector,
                1,
                deadline
            )
        );
        hook.settleIntent(1, 96e18);
    }
    
    function test_RevertIfSettleAlreadySettled() public {
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity to initialize pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        uint256 minOut = 95e18;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        // Encode as [0x01][abi.encode(minOut, deadline)]
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));
        
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // Small amount to avoid price limit issues
        
        swap(poolKey, zeroForOne, amountSpecified, hookData);
        
        // Settle once
        hook.settleIntent(1, 96e18);
        
        // Try to settle again - should revert with custom error
        vm.expectRevert(
            abi.encodeWithSelector(
                RecorrHookTypes.IntentAlreadySettled.selector,
                1
            )
        );
        hook.settleIntent(1, 96e18);
    }
    
    // =============================================================
    //                    PHASE 5 TESTS (DYNAMIC FEES)
    // =============================================================
    
    function test_DynamicFeeCalculation() public {
        // Set corridor pool with fee params
        hook.setCorridorPool(poolKey, true);
        
        RecorrHookTypes.FeeParams memory feeParams = RecorrHookTypes.FeeParams({
            baseFee: 500,          // 0.05%
            maxExtraFee: 5000,     // 0.5%
            netFlowThreshold: 1000e18  // 1000 tokens
        });
        hook.setPoolFeeParams(poolKey, feeParams);
        
        // Add liquidity first
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Perform immediate swap (not async) to trigger dynamic fees
        bool zeroForOne = true;
        int256 amountSpecified = -100e18;
        
        // First swap - should use base fee (no netFlow yet)
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // NetFlow should be tracked after swap
        int256 flow = hook.getNetFlow(poolKey);
        assertGt(flow, 0, "NetFlow should be positive after zeroForOne swap");
    }
    
    function test_NetFlowTracking() public {
        hook.setCorridorPool(poolKey, true);
        
        // Add liquidity first
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Get initial netFlow
        int256 initialFlow = hook.getNetFlow(poolKey);
        assertEq(initialFlow, 0, "Initial netFlow should be 0");
        
        // Perform zeroForOne swap
        bool zeroForOne1 = true;
        int256 amountSpecified1 = -100e18;
        swap(poolKey, zeroForOne1, amountSpecified1, ZERO_BYTES);
        
        int256 flowAfterFirst = hook.getNetFlow(poolKey);
        assertGt(flowAfterFirst, initialFlow, "NetFlow should increase after zeroForOne");
        
        // Perform oneForZero swap (opposite direction)
        bool zeroForOne2 = false;
        int256 amountSpecified2 = -50e18;
        swap(poolKey, zeroForOne2, amountSpecified2, ZERO_BYTES);
        
        int256 flowAfterSecond = hook.getNetFlow(poolKey);
        assertLt(flowAfterSecond, flowAfterFirst, "NetFlow should decrease after oneForZero");
    }

    // =============================================================
    //                  NEGATIVE TESTS
    // =============================================================

    function test_SetPoolFeeParamsRevertsIfPoolIsNotDynamic() public {
        // Create a pool with static fee (not DYNAMIC_FEE_FLAG)
        PoolKey memory staticPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // Static fee, not 0x800000
            tickSpacing: 60,
            hooks: hook
        });

        RecorrHookTypes.FeeParams memory params = RecorrHookTypes.FeeParams({
            baseFee: 500,
            maxExtraFee: 1000,
            netFlowThreshold: 1e18
        });

        vm.expectRevert("RecorrHook: pool not dynamic");
        hook.setPoolFeeParams(staticPoolKey, params);
    }

    function test_SetCorridorPoolRevertsIfWrongHook() public {
        // Create a pool with a different hook address
        PoolKey memory wrongHookKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: RecorrHook(address(0xBEEF)) // Different hook address
        });

        vm.expectRevert("RecorrHook: wrong hook");
        hook.setCorridorPool(wrongHookKey, true);
    }
}
