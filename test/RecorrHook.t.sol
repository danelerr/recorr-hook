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
 * @notice Test suite for RecorrHook Phase 1 - Basic skeleton functionality
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
