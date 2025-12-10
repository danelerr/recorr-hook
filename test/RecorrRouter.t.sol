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
import {RecorrRouter} from "../contracts/RecorrRouter.sol";
import {MockBridge} from "../contracts/MockBridge.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RecorrRouterTest
 * @notice Test suite for RecorrRouter (Swap & Bridge periphery)
 * @dev Tests router functionality, bridge integration, and user flows
 */
contract RecorrRouterTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    RecorrHook hook;
    RecorrRouter router;
    MockBridge bridge;
    PoolKey poolKey;
    PoolId poolId;

    address user = address(0x1234);
    uint256 constant STARTING_BALANCE = 1000 ether;

    function setUp() public {
        // Deploy v4-core contracts
        deployFreshManagerAndRouters();
        
        // Deploy and approve currencies
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Calculate hook permission flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // Mine hook address with correct permission bits
        bytes memory constructorArgs = abi.encode(address(manager));
        (address expectedHookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(RecorrHook).creationCode,
            constructorArgs
        );

        // Deploy hook
        hook = new RecorrHook{salt: salt}(IPoolManager(address(manager)));
        assertEq(address(hook), expectedHookAddress, "hook address mismatch");

        // Deploy router
        router = new RecorrRouter(IPoolManager(address(manager)), hook);

        // Deploy bridge
        bridge = new MockBridge();
        router.setBridge(bridge);

        // Create test pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Set as corridor pool
        hook.setCorridorPool(poolKey, true);

        // Add liquidity
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

        // Setup user with tokens and approvals
        vm.startPrank(user);
        deal(Currency.unwrap(currency0), user, STARTING_BALANCE);
        deal(Currency.unwrap(currency1), user, STARTING_BALANCE);
        
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // =============================================================
    //                     CONSTRUCTOR TESTS
    // =============================================================

    function test_ConstructorSetsPoolManager() public view {
        assertEq(address(router.poolManager()), address(manager));
    }

    function test_ConstructorSetsRecorrHook() public view {
        assertEq(address(router.recorrHook()), address(hook));
    }

    function test_BridgeCanBeSet() public view {
        assertEq(address(router.bridge()), address(bridge));
    }

    // =============================================================
    //                       SWAP TESTS
    // =============================================================

    function test_SwapExecutesSuccessfully() public {
        vm.startPrank(user);

        uint256 balanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(user);

        // Execute swap through router
        uint256 amountOut = router.swap(
            poolKey,
            true, // zeroForOne
            -1e18, // 1 token in
            MIN_PRICE_LIMIT,
            ZERO_BYTES, // immediate swap
            0.2e18 // min 0.2 out (realistic with fees)
        );

        uint256 balanceAfter = IERC20(Currency.unwrap(currency1)).balanceOf(user);

        assertGt(amountOut, 0, "Should receive output tokens");
        assertGt(balanceAfter, balanceBefore, "Balance should increase");
        
        vm.stopPrank();
    }

    function test_SwapRevertsWithWrongHook() public {
        // Create pool with no hook
        PoolKey memory wrongKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hook // Wrong hook for this test
        });

        // Change hooks to address(0) to simulate wrong hook
        wrongKey.hooks = RecorrHook(address(0));

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecorrRouter.InvalidPoolHook.selector,
                address(hook),
                address(0)
            )
        );
        router.swap(
            wrongKey,
            true,
            -1e18,
            MIN_PRICE_LIMIT,
            ZERO_BYTES,
            0.9e18
        );
        vm.stopPrank();
    }

    function test_SwapRevertsOnSlippageExceeded() public {
        vm.startPrank(user);

        // Try swap with unrealistic minAmountOut
        vm.expectRevert(
            abi.encodeWithSelector(
                RecorrRouter.SlippageExceeded.selector,
                299535495591078093, // Actual output (~0.3e18)
                100e18 // Unrealistic minimum
            )
        );
        router.swap(
            poolKey,
            true,
            -1e18,
            MIN_PRICE_LIMIT,
            ZERO_BYTES,
            100e18 // Unrealistic: expect 100 out from 1 in
        );

        vm.stopPrank();
    }

    function test_SwapWithAsyncIntent() public {
        // Set both msg.sender and tx.origin to user
        // This is needed because the hook uses tx.origin for intent ownership
        vm.prank(user, user);

        uint256 minOut = 0.2e18; // Realistic with fees
        uint48 deadline = uint48(block.timestamp + 1 hours);
        bytes memory hookData = abi.encodePacked(uint8(0x01), abi.encode(minOut, deadline));

        // Execute async swap (creates intent)
        router.swap(
            poolKey,
            true,
            -1e18,
            MIN_PRICE_LIMIT,
            hookData,
            minOut
        );

        // Verify intent was created
        RecorrHookTypes.Intent memory intent = hook.getIntent(1);
        assertEq(intent.owner, user, "Intent owner should be user");
        assertFalse(intent.settled, "Intent should not be settled yet");
    }

    // =============================================================
    //                   SWAP & BRIDGE TESTS
    // =============================================================

    function test_SwapAndBridgeExecutes() public {
        vm.startPrank(user);

        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(user);

        // Prepare bridge params
        RecorrHookTypes.BridgeParams memory bridgeParams = RecorrHookTypes.BridgeParams({
            token: Currency.unwrap(currency1),
            to: user,
            destChainData: abi.encode(uint256(137)) // Mock: Polygon chain ID
        });

        // Execute swap & bridge
        uint256 amountOut = router.swapAndBridge(
            poolKey,
            true, // zeroForOne
            -1e18,
            MIN_PRICE_LIMIT,
            0.2e18, // min output (realistic with fees)
            bridgeParams
        );

        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(user);

        assertGt(amountOut, 0, "Should have output amount");
        assertLt(balanceAfter, balanceBefore, "Input tokens should be spent");

        // Verify bridge received tokens
        uint256 bridgeBalance = IERC20(Currency.unwrap(currency1)).balanceOf(address(bridge));
        assertGt(bridgeBalance, 0, "Bridge should hold tokens");

        vm.stopPrank();
    }

    function test_SwapAndBridgeRevertsWithNoBridge() public {
        // Deploy new router without bridge
        RecorrRouter routerNoBridge = new RecorrRouter(
            IPoolManager(address(manager)),
            hook
        );

        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(routerNoBridge), type(uint256).max);

        RecorrHookTypes.BridgeParams memory bridgeParams = RecorrHookTypes.BridgeParams({
            token: Currency.unwrap(currency1),
            to: user,
            destChainData: abi.encode(uint256(137))
        });

        vm.expectRevert(RecorrRouter.ZeroAddress.selector);
        routerNoBridge.swapAndBridge(
            poolKey,
            true,
            -1e18,
            MIN_PRICE_LIMIT,
            0.9e18,
            bridgeParams
        );

        vm.stopPrank();
    }

    function test_SwapAndBridgeEmitsEvents() public {
        vm.startPrank(user);

        RecorrHookTypes.BridgeParams memory bridgeParams = RecorrHookTypes.BridgeParams({
            token: Currency.unwrap(currency1),
            to: user,
            destChainData: abi.encode(uint256(137))
        });

        // Expect SwapAndBridgeExecuted event
        vm.expectEmit(true, true, true, false);
        emit RecorrRouter.SwapAndBridgeExecuted(
            user,
            poolId,
            Currency.unwrap(currency1),
            0, // We don't know exact amount
            bridgeParams.destChainData
        );

        router.swapAndBridge(
            poolKey,
            true,
            -1e18,
            MIN_PRICE_LIMIT,
            0.2e18, // min output (realistic with fees)
            bridgeParams
        );

        vm.stopPrank();
    }

    // =============================================================
    //                      VIEW TESTS
    // =============================================================

    function test_IsCorridorPool() public view {
        assertTrue(router.isCorridorPool(poolKey));
    }

    function test_GetHook() public view {
        assertEq(router.getHook(), address(hook));
    }

    // =============================================================
    //                    BRIDGE TESTS
    // =============================================================

    function test_BridgeDefaultFee() public view {
        uint256 fee = bridge.getBridgeFee(Currency.unwrap(currency0));
        assertEq(fee, bridge.DEFAULT_FEE_BPS(), "Should use default fee");
    }

    function test_BridgeSetCustomFee() public {
        address token = Currency.unwrap(currency0);
        uint256 customFee = 50; // 0.5%

        bridge.setBridgeFee(token, customFee);
        
        assertEq(bridge.getBridgeFee(token), customFee, "Should use custom fee");
    }

    function test_BridgeTracksVolume() public {
        vm.startPrank(user);

        // Approve bridge
        IERC20(Currency.unwrap(currency1)).approve(address(bridge), type(uint256).max);

        address token = Currency.unwrap(currency1);
        uint256 volumeBefore = bridge.getTotalBridged(token);

        // Bridge directly
        bridge.bridge(
            token,
            user,
            1e18,
            abi.encode(uint256(137))
        );

        uint256 volumeAfter = bridge.getTotalBridged(token);
        assertGt(volumeAfter, volumeBefore, "Volume should increase");

        vm.stopPrank();
    }
}
