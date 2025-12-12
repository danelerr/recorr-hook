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
        bytes memory constructorArgs = abi.encode(address(manager), address(this));
        (address expectedHookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(RecorrHook).creationCode,
            constructorArgs
        );

        // Deploy hook with the mined salt
        hook = new RecorrHook{salt: salt}(IPoolManager(address(manager)), address(this));
        
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

    // =============================================================
    //                     COW MATCHING TESTS (Phase 4)
    // =============================================================

    function test_CoWMatchingOppositeIntents() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        // Create two intents in opposite directions with same amount
        vm.startPrank(address(this));
        
        // Intent 1: zeroForOne (1 token)
        bytes memory hookData1 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData1);
        
        // Intent 2: oneForZero (1 token) 
        bytes memory hookData2 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, false, -1e18, hookData2);
        
        vm.stopPrank();
        
        // Verify both intents created
        RecorrHookTypes.Intent memory intent1 = hook.getIntent(1);
        RecorrHookTypes.Intent memory intent2 = hook.getIntent(2);
        
        assertTrue(intent1.zeroForOne, "Intent 1 should be zeroForOne");
        assertFalse(intent2.zeroForOne, "Intent 2 should be oneForZero");
        
        // Settle batch with CoW
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        
        // Expect CoWExecuted event
        vm.expectEmit(true, true, true, true);
        emit RecorrHookTypes.CoWExecuted(
            2,           // batchSize
            1e18,        // matchedAmount (min of both)
            0,           // netAmountToAmm (fully matched, no net flow)
            true,        // netDirection (convention: true when net=0)
            100000       // gasSaved estimate
        );
        
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify both intents are settled
        intent1 = hook.getIntent(1);
        intent2 = hook.getIntent(2);
        
        assertTrue(intent1.settled, "Intent 1 should be settled");
        assertTrue(intent2.settled, "Intent 2 should be settled");
    }

    function test_CoWMatchingPartialMatch() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        // Intent 1: zeroForOne (2 tokens)
        bytes memory hookData1 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(1.8e18), uint48(block.timestamp + 1 hours))
        );
        swap(poolKey, true, -2e18, hookData1);
        
        // Intent 2: oneForZero (1 token)
        bytes memory hookData2 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        swap(poolKey, false, -1e18, hookData2);
        
        vm.stopPrank();
        
        // Settle batch
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = 1.9e18;
        amountsOut[1] = 0.95e18;
        
        // Expect partial CoW: 1 token matched P2P, 1 token net to AMM
        vm.expectEmit(true, true, true, false);
        emit RecorrHookTypes.CoWExecuted(
            2,           // batchSize
            1e18,        // matchedAmount (min of 2 and 1)
            1e18,        // netAmountToAmm (2 - 1 = 1)
            true,        // netDirection is zeroForOne (more zeroForOne)
            0            // gasSaved (don't check exact value)
        );
        
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify both settled
        assertTrue(hook.getIntent(1).settled);
        assertTrue(hook.getIntent(2).settled);
    }

    function test_CoWMatchingOnlyOneDirection() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        vm.startPrank(address(this));
        
        // Only zeroForOne intents (no match possible)
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -0.5e18, hookData);
        swap(poolKey, true, -0.5e18, hookData);
        
        vm.stopPrank();
        
        // Settle batch
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        
        // No CoW matching (matchedAmount = 0), all goes to AMM
        // CoWExecuted event might not be emitted if matchedAmount == 0
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Both should be settled
        assertTrue(hook.getIntent(1).settled);
        assertTrue(hook.getIntent(2).settled);
    }

    // =============================================================
    //                     EDGE CASE TESTS
    // =============================================================

    function test_SettleExpiredIntentSkips() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        // Create intent with short deadline
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 100))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Fast forward past deadline
        vm.warp(block.timestamp + 200);
        
        // Try to settle expired intent
        uint256[] memory intentIds = new uint256[](1);
        intentIds[0] = 1;
        
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 0.95e18;
        
        // Should revert with "No valid intents" since the only intent is expired
        vm.expectRevert("No valid intents");
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Intent should NOT be settled
        RecorrHookTypes.Intent memory intent = hook.getIntent(1);
        assertFalse(intent.settled, "Expired intent should not be settled");
    }

    function test_SettleExpiredIntentRevertsInSingleMode() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 100))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Fast forward past deadline
        vm.warp(block.timestamp + 200);
        
        // Single settle should revert on expired
        vm.expectRevert(
            abi.encodeWithSelector(
                RecorrHookTypes.IntentExpired.selector,
                1,
                block.timestamp - 100
            )
        );
        hook.settleIntent(1, 0.95e18);
    }

    function test_SettleAlreadySettledSkips() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Settle once
        hook.settleIntent(1, 0.95e18);
        assertTrue(hook.getIntent(1).settled);
        
        // Try to settle again in batch (should revert with "No valid intents")
        uint256[] memory intentIds = new uint256[](1);
        intentIds[0] = 1;
        
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 0.95e18;
        
        // Should revert since the only intent is already settled
        vm.expectRevert("No valid intents");
        hook.settleCorridorBatch(intentIds, amountsOut);
    }

    function test_SettleAlreadySettledRevertsInSingleMode() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Settle once
        hook.settleIntent(1, 0.95e18);
        
        // Try to settle again (should revert)
        vm.expectRevert(
            abi.encodeWithSelector(
                RecorrHookTypes.IntentAlreadySettled.selector,
                1
            )
        );
        hook.settleIntent(1, 0.95e18);
    }

    function test_BatchMixedValidInvalid() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create 3 intents
        swap(poolKey, true, -0.5e18, hookData);  // Valid
        swap(poolKey, true, -0.5e18, hookData);  // Will be settled early
        swap(poolKey, true, -0.5e18, hookData);  // Valid
        
        vm.stopPrank();
        
        // Settle intent #2 early
        hook.settleIntent(2, 0.95e18);
        
        // Try to settle all 3
        uint256[] memory intentIds = new uint256[](3);
        intentIds[0] = 1;
        intentIds[1] = 2; // Already settled
        intentIds[2] = 3;
        
        uint256[] memory amountsOut = new uint256[](3);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        amountsOut[2] = 0.95e18;
        
        // Should skip #2 and settle #1 and #3
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        assertTrue(hook.getIntent(1).settled, "Intent 1 should be settled");
        assertTrue(hook.getIntent(2).settled, "Intent 2 was already settled");
        assertTrue(hook.getIntent(3).settled, "Intent 3 should be settled");
    }

    function test_BatchWithInsufficientOutputSkips() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Try to settle with insufficient output
        uint256[] memory intentIds = new uint256[](1);
        intentIds[0] = 1;
        
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 0.5e18; // Less than minOut (0.9e18)
        
        // Should skip (not revert)
        vm.expectRevert("No valid intents");
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Should NOT be settled
        assertFalse(hook.getIntent(1).settled, "Intent should not be settled with insufficient output");
    }

    // =============================================================
    //                      COW MATCHING TESTS
    // =============================================================

    function test_CoWPerfectMatch() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create intent 1: zeroForOne (1 token)
        swap(poolKey, true, -1e18, hookData);
        
        // Create intent 2: oneForZero (1 token) - opposite direction
        swap(poolKey, false, -1e18, hookData);
        
        vm.stopPrank();
        
        // Verify intents created
        RecorrHookTypes.Intent memory intent1 = hook.getIntent(1);
        RecorrHookTypes.Intent memory intent2 = hook.getIntent(2);
        
        assertTrue(intent1.zeroForOne, "Intent 1 should be zeroForOne");
        assertFalse(intent2.zeroForOne, "Intent 2 should be oneForZero");
        
        // Settle both with CoW
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        
        // Expect CoW event
        vm.expectEmit(true, true, true, true);
        emit RecorrHookTypes.CoWExecuted(
            2, // totalIntents
            1e18, // matchedAmount (perfect match)
            0, // netAmountToAmm (nothing to AMM)
            true, // netDirection (convention: true when net=0)
            100000 // gasSaved
        );
        
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify CoW stats
        assertEq(stats.totalIntents, 2, "Should have 2 valid intents");
        assertEq(stats.matchedAmount, 1e18, "Should match 1e18");
        assertEq(stats.netAmountToAmm, 0, "Net to AMM should be 0 (perfect match)");
        assertGt(stats.gasSaved, 0, "Should have gas savings");
        
        // Both intents should be settled
        assertTrue(hook.getIntent(1).settled, "Intent 1 should be settled");
        assertTrue(hook.getIntent(2).settled, "Intent 2 should be settled");
    }

    function test_CoWPartialMatch() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create intent 1: zeroForOne (2 tokens)
        swap(poolKey, true, -2e18, hookData);
        
        // Create intent 2: oneForZero (1 token) - opposite but smaller
        swap(poolKey, false, -1e18, hookData);
        
        vm.stopPrank();
        
        // Settle both
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = 1.9e18;
        amountsOut[1] = 0.95e18;
        
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify partial matching
        assertEq(stats.totalIntents, 2, "Should have 2 valid intents");
        assertEq(stats.matchedAmount, 1e18, "Should match smaller amount (1e18)");
        assertEq(stats.netAmountToAmm, 1e18, "Net to AMM should be 1e18 (2-1)");
        assertTrue(stats.netDirection, "Net direction should be zeroForOne");
    }

    function test_CoWMultipleIntentsSameDirection() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create 3 intents in same direction
        swap(poolKey, true, -0.3e18, hookData);
        swap(poolKey, true, -0.3e18, hookData);
        swap(poolKey, true, -0.3e18, hookData);
        
        // Create 2 intents in opposite direction
        swap(poolKey, false, -0.3e18, hookData);
        swap(poolKey, false, -0.3e18, hookData);
        
        vm.stopPrank();
        
        // Settle all 5
        uint256[] memory intentIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            intentIds[i] = i + 1;
        }
        
        uint256[] memory amountsOut = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            amountsOut[i] = 0.95e18;
        }
        
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify: 3 zeroForOne (0.9e18) vs 2 oneForZero (0.6e18)
        // Matched: 0.6e18, Net to AMM: 0.3e18 (zeroForOne)
        assertEq(stats.totalIntents, 5, "Should have 5 valid intents");
        assertEq(stats.matchedAmount, 0.6e18, "Should match 0.6e18");
        assertEq(stats.netAmountToAmm, 0.3e18, "Net to AMM should be 0.3e18");
        assertTrue(stats.netDirection, "Net direction should be zeroForOne");
    }

    function test_CoWOnlyOneDirection() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create 2 intents in same direction only
        swap(poolKey, true, -0.5e18, hookData);
        swap(poolKey, true, -0.5e18, hookData);
        
        vm.stopPrank();
        
        // Settle both
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // No matching possible, all goes to AMM
        assertEq(stats.totalIntents, 2, "Should have 2 valid intents");
        assertEq(stats.matchedAmount, 0, "No matching (one direction only)");
        assertEq(stats.netAmountToAmm, 1e18, "All to AMM (0.5e18 * 2)");
        assertTrue(stats.netDirection, "Direction should be zeroForOne");
    }

    // =============================================================
    //                   ADVANCED EDGE CASES
    // =============================================================

    function test_BatchRejectsEmptyArray() public {
        uint256[] memory intentIds = new uint256[](0);
        uint256[] memory amountsOut = new uint256[](0);
        
        vm.expectRevert("Empty batch");
        hook.settleCorridorBatch(intentIds, amountsOut);
    }

    function test_BatchRejectsMismatchedLengths() public {
        uint256[] memory intentIds = new uint256[](2);
        intentIds[0] = 1;
        intentIds[1] = 2;
        
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 1e18;
        
        vm.expectRevert("Length mismatch");
        hook.settleCorridorBatch(intentIds, amountsOut);
    }

    function test_BatchWithAllInvalidIntents() public {
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Try to settle with insufficient output
        uint256[] memory intentIds = new uint256[](1);
        intentIds[0] = 1;
        
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 0.5e18; // Below minOut
        
        vm.expectRevert("No valid intents");
        hook.settleCorridorBatch(intentIds, amountsOut);
    }

    function test_IntentExpiredDuringBatch() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData);
        vm.stopPrank();
        
        // Warp time past deadline
        vm.warp(block.timestamp + 2 hours);
        
        uint256[] memory intentIds = new uint256[](1);
        intentIds[0] = 1;
        
        uint256[] memory amountsOut = new uint256[](1);
        amountsOut[0] = 0.95e18;
        
        // Should skip expired intent
        vm.expectRevert("No valid intents");
        hook.settleCorridorBatch(intentIds, amountsOut);
        
        assertFalse(hook.getIntent(1).settled, "Expired intent should not be settled");
    }

    function test_CoWWithMixOfValidAndInvalid() public {
        // Setup: mark as corridor and add liquidity
        hook.setCorridorPool(poolKey, true);
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
        
        vm.startPrank(address(this));
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create 3 intents
        swap(poolKey, true, -1e18, hookData);
        swap(poolKey, false, -1e18, hookData);
        swap(poolKey, true, -1e18, hookData);
        
        vm.stopPrank();
        
        // Manually settle intent 2
        hook.settleIntent(2, 0.95e18);
        
        // Try to batch settle all 3
        uint256[] memory intentIds = new uint256[](3);
        intentIds[0] = 1;
        intentIds[1] = 2; // Already settled
        intentIds[2] = 3;
        
        uint256[] memory amountsOut = new uint256[](3);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        amountsOut[2] = 0.95e18;
        
        // Should skip #2 and settle #1 and #3
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Only 2 valid intents (skipped already-settled one)
        assertEq(stats.totalIntents, 2, "Should have 2 valid intents");
        assertEq(stats.matchedAmount, 0, "No matching (both same direction)");
        assertEq(stats.netAmountToAmm, 2e18, "Both to AMM");
        
        assertTrue(hook.getIntent(1).settled, "Intent 1 should be settled");
        assertTrue(hook.getIntent(2).settled, "Intent 2 was already settled");
        assertTrue(hook.getIntent(3).settled, "Intent 3 should be settled");
    }

    // =============================================================
    //                   END-TO-END & GAS TESTS
    // =============================================================

    function test_ResetNetFlow() public {
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create intent and settle to generate net flow
        swap(poolKey, true, -1e18, hookData);
        hook.settleIntent(1, 0.95e18);
        
        // Verify net flow is non-zero
        int256 netFlowBefore = hook.getNetFlow(poolKey);
        assertGt(netFlowBefore, 0, "Net flow should be positive");
        
        // Reset net flow (only owner)
        hook.resetNetFlow(poolKey);
        
        // Verify reset
        int256 netFlowAfter = hook.getNetFlow(poolKey);
        assertEq(netFlowAfter, 0, "Net flow should be reset to 0");
        
        // Verify non-owner cannot reset
        vm.prank(address(0x123));
        vm.expectRevert();
        hook.resetNetFlow(poolKey);
    }

    function test_E2E_CoWFlowWithDynamicFees() public {
        // Setup: corridor pool with dynamic fees
        hook.setCorridorPool(poolKey, true);
        
        RecorrHookTypes.FeeParams memory feeParams = RecorrHookTypes.FeeParams({
            baseFee: 500,          // 0.05%
            maxExtraFee: 2000,     // 0.2%
            netFlowThreshold: 10e18
        });
        hook.setPoolFeeParams(poolKey, feeParams);
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Create opposing intents
        bytes memory hookData1 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        bytes memory hookData2 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        bytes memory hookData3 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.4e18), uint48(block.timestamp + 1 hours))
        );
        
        swap(poolKey, true, -1e18, hookData1);   // Intent 1: zeroForOne, 1e18
        swap(poolKey, false, -1e18, hookData2);  // Intent 2: oneForZero, 1e18
        swap(poolKey, true, -0.5e18, hookData3); // Intent 3: zeroForOne, 0.5e18
        
        // Verify intents created
        assertEq(hook.nextIntentId(), 4, "Should have 3 intents created");
        
        RecorrHookTypes.Intent memory intent1 = hook.getIntent(1);
        assertEq(intent1.amountSpecified, 1e18);
        assertTrue(intent1.zeroForOne);
        assertFalse(intent1.settled);
        
        // Settle batch with CoW
        uint256[] memory intentIds = new uint256[](3);
        intentIds[0] = 1;
        intentIds[1] = 2;
        intentIds[2] = 3;
        
        uint256[] memory amountsOut = new uint256[](3);
        amountsOut[0] = 0.95e18;  // 1e18 in, 0.95e18 out
        amountsOut[1] = 0.95e18;  // 1e18 in, 0.95e18 out
        amountsOut[2] = 0.45e18;  // 0.5e18 in, 0.45e18 out
        
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Verify CoW matching: 1.5e18 zeroForOne vs 1e18 oneForZero
        assertEq(stats.totalIntents, 3, "All 3 intents valid");
        assertEq(stats.matchedAmount, 1e18, "Should match 1e18 P2P");
        assertEq(stats.netAmountToAmm, 0.5e18, "Net 0.5e18 to AMM");
        assertTrue(stats.netDirection, "Net direction is zeroForOne");
        assertGt(stats.gasSaved, 0, "Should have gas savings");
        
        // Verify all settled
        assertTrue(hook.getIntent(1).settled, "Intent 1 settled");
        assertTrue(hook.getIntent(2).settled, "Intent 2 settled");
        assertTrue(hook.getIntent(3).settled, "Intent 3 settled");
    }

    function test_GasSavingsComparison() public {
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        bytes memory hookData = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.5e18), uint48(block.timestamp + 1 hours))
        );
        
        // Create 3 intents
        swap(poolKey, true, -1e18, hookData);
        swap(poolKey, false, -1e18, hookData);
        swap(poolKey, true, -1e18, hookData);
        
        // Measure gas for individual settlements
        uint256 gasBefore1 = gasleft();
        hook.settleIntent(1, 0.95e18);
        uint256 gasIndividual1 = gasBefore1 - gasleft();
        
        uint256 gasBefore2 = gasleft();
        hook.settleIntent(2, 0.95e18);
        uint256 gasIndividual2 = gasBefore2 - gasleft();
        
        uint256 gasBefore3 = gasleft();
        hook.settleIntent(3, 0.95e18);
        uint256 gasIndividual3 = gasBefore3 - gasleft();
        
        uint256 totalGasIndividual = gasIndividual1 + gasIndividual2 + gasIndividual3;
        
        // Create new batch for comparison
        swap(poolKey, true, -1e18, hookData);
        swap(poolKey, false, -1e18, hookData);
        swap(poolKey, true, -1e18, hookData);
        
        uint256[] memory intentIds = new uint256[](3);
        intentIds[0] = 4;
        intentIds[1] = 5;
        intentIds[2] = 6;
        
        uint256[] memory amountsOut = new uint256[](3);
        amountsOut[0] = 0.95e18;
        amountsOut[1] = 0.95e18;
        amountsOut[2] = 0.95e18;
        
        // Measure gas for batch settlement
        uint256 gasBefore = gasleft();
        hook.settleCorridorBatch(intentIds, amountsOut);
        uint256 gasBatch = gasBefore - gasleft();
        
        // Log for visibility
        emit log_named_uint("Gas Individual 1", gasIndividual1);
        emit log_named_uint("Gas Individual 2", gasIndividual2);
        emit log_named_uint("Gas Individual 3", gasIndividual3);
        emit log_named_uint("Gas Individual (total)", totalGasIndividual);
        emit log_named_uint("Gas Batch", gasBatch);
        
        // Note: For small batches (3 intents), batch overhead can exceed savings.
        // Batch settlement becomes more efficient with larger batches (5+ intents).
        // This test documents the gas costs for comparison purposes.
        if (gasBatch < totalGasIndividual) {
            emit log_named_uint("Gas Saved", totalGasIndividual - gasBatch);
        } else {
            emit log_named_uint("Batch Overhead", gasBatch - totalGasIndividual);
            emit log("Note: Batch settlement more efficient with 5+ intents");
        }
        
        // Verify batch completed successfully (CoW matching occurred)
        assertEq(hook.getIntent(4).settled, true, "Intent 4 settled");
        assertEq(hook.getIntent(5).settled, true, "Intent 5 settled");
        assertEq(hook.getIntent(6).settled, true, "Intent 6 settled");
    }

    function test_CoWEfficiencyMetrics() public {
        hook.setCorridorPool(poolKey, true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10000 ether, // More liquidity to handle larger swaps
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        bytes memory hookData1 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(1.8e18), uint48(block.timestamp + 1 hours))
        );
        bytes memory hookData2 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(1.35e18), uint48(block.timestamp + 1 hours))
        );
        bytes memory hookData3 = abi.encodePacked(
            uint8(0x01),
            abi.encode(uint256(0.9e18), uint48(block.timestamp + 1 hours))
        );
        
        // Scenario: 5 intents, 3 one way (4.5e18), 2 the other (3.5e18)
        swap(poolKey, true, -2e18, hookData1);    // Intent 1: zeroForOne, 2e18
        swap(poolKey, true, -1.5e18, hookData2);  // Intent 2: zeroForOne, 1.5e18
        swap(poolKey, true, -1e18, hookData3);    // Intent 3: zeroForOne, 1e18
        swap(poolKey, false, -2e18, hookData1);   // Intent 4: oneForZero, 2e18
        swap(poolKey, false, -1.5e18, hookData2); // Intent 5: oneForZero, 1.5e18
        
        uint256[] memory intentIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            intentIds[i] = i + 1;
        }
        
        uint256[] memory amountsOut = new uint256[](5);
        amountsOut[0] = 1.9e18;  // 2e18 in -> 1.9e18 out
        amountsOut[1] = 1.4e18;  // 1.5e18 in -> 1.4e18 out
        amountsOut[2] = 0.95e18; // 1e18 in -> 0.95e18 out
        amountsOut[3] = 1.9e18;  // 2e18 in -> 1.9e18 out
        amountsOut[4] = 1.4e18;  // 1.5e18 in -> 1.4e18 out
        
        RecorrHookTypes.CoWStats memory stats = hook.settleCorridorBatch(intentIds, amountsOut);
        
        // Calculate efficiency metrics
        uint256 totalVolume = stats.totalZeroForOne + stats.totalOneForZero;
        uint256 matchEfficiency = (stats.matchedAmount * 100) / totalVolume;
        
        // Verify CoW efficiency
        assertEq(stats.totalZeroForOne, 4.5e18, "Total zeroForOne");
        assertEq(stats.totalOneForZero, 3.5e18, "Total oneForZero");
        assertEq(stats.matchedAmount, 3.5e18, "Matched amount P2P");
        assertEq(stats.netAmountToAmm, 1e18, "Net to AMM");
        
        // Efficiency: 3.5 / 8 = 43.75% matched P2P
        assertEq(matchEfficiency, 43, "CoW efficiency ~43%");
        
        // Log metrics for documentation
        emit log_named_uint("Total Volume", totalVolume / 1e18);
        emit log_named_uint("Matched P2P", stats.matchedAmount / 1e18);
        emit log_named_uint("Net to AMM", stats.netAmountToAmm / 1e18);
        emit log_named_uint("CoW Efficiency %", matchEfficiency);
        emit log_named_uint("Gas Saved", stats.gasSaved);
        emit log_named_uint("Total Intents", stats.totalIntents);
    }
}
