// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "../lib/v4-core/test/utils/CurrencySettler.sol";
import {RecorrHook} from "./RecorrHook.sol";
import {RecorrHookTypes} from "./RecorrHookTypes.sol";
import {IMockBridge} from "./interfaces/IMockBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RecorrRouter
 * @notice Periphery contract for RecorrHook - Swap & Bridge integration
 * @dev Provides user-friendly interface for:
 *      - Swap in corridor pools (immediate or async)
 *      - Swap + Bridge atomically (cross-chain corridors)
 * 
 * Architecture:
 * User → RecorrRouter → PoolManager (via RecorrHook) → [optional] MockBridge
 * 
 * Key Features:
 * - Follows official Uniswap V4 unlock/callback pattern
 * - Symmetric settle/take logic for both tokens (like PoolSwapTest)
 * - Slippage protection via minAmountOut
 * - Support for both immediate and async (intent) swaps
 * - Optional bridge integration for cross-chain flows
 * 
 * @custom:security This is a periphery contract - users approve this router
 * - Always validate PoolKey matches expected hook
 * - Use SafeERC20 for all token transfers
 * - Validate slippage parameters
 */
contract RecorrRouter is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // =============================================================
    //                       STATE VARIABLES
    // =============================================================

    /// @notice The Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice The RecorrHook instance
    RecorrHook public immutable recorrHook;

    /// @notice The bridge contract for cross-chain transfers
    IMockBridge public bridge;

    // =============================================================
    //                      CALLBACK DATA
    // =============================================================

    struct SwapCallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    struct BridgeCallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        RecorrHookTypes.BridgeParams bridgeParams;
    }

    // =============================================================
    //                           EVENTS
    // =============================================================

    event SwapExecuted(
        address indexed user,
        PoolId indexed poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountOut
    );

    event SwapAndBridgeExecuted(
        address indexed user,
        PoolId indexed poolId,
        address indexed token,
        uint256 amountOut,
        bytes destChainData
    );

    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);

    // =============================================================
    //                           ERRORS
    // =============================================================

    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error InvalidPoolHook(address expected, address actual);
    error ZeroAddress();
    error NotPoolManager();

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /**
     * @notice Initialize the router
     * @param _poolManager The Uniswap V4 PoolManager
     * @param _recorrHook The RecorrHook instance
     */
    constructor(IPoolManager _poolManager, RecorrHook _recorrHook) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_recorrHook) == address(0)) revert ZeroAddress();

        poolManager = _poolManager;
        recorrHook = _recorrHook;
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set the bridge contract
     * @dev In production, add access control (onlyOwner)
     * @param _bridge The new bridge contract address
     */
    function setBridge(IMockBridge _bridge) external {
        address oldBridge = address(bridge);
        bridge = _bridge;
        emit BridgeUpdated(oldBridge, address(_bridge));
    }

    // =============================================================
    //                      SWAP FUNCTIONS
    // =============================================================

    /**
     * @notice Execute a swap in a corridor pool
     * @dev Supports both immediate swaps and async intents via hookData
     * @param key The pool key
     * @param zeroForOne Swap direction
     * @param amountSpecified Amount to swap (negative for exact input)
     * @param sqrtPriceLimitX96 Price limit
     * @param hookData Encoded swap mode (0x00 = immediate, 0x01 = async intent)
     * @param minAmountOut Minimum output amount for slippage protection
     * @return amountOut The actual output amount
     */
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        // Validate pool uses RecorrHook
        if (address(key.hooks) != address(recorrHook)) {
            revert InvalidPoolHook(address(recorrHook), address(key.hooks));
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            key: key,
            params: params,
            hookData: hookData
        });

        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(true, data)), // true = swap (not bridge)
            (BalanceDelta)
        );

        // Output is the token on the "other" side of the swap
        int128 deltaAmount = zeroForOne ? delta.amount1() : delta.amount0();
        if (deltaAmount > 0) {
            amountOut = uint256(uint128(deltaAmount));
        }

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        emit SwapExecuted(
            msg.sender,
            key.toId(),
            zeroForOne,
            amountSpecified,
            amountOut
        );

        return amountOut;
    }

    /**
     * @notice Execute a swap and bridge the output cross-chain
     * @dev Atomic swap + bridge for cross-chain corridors
     * @param key The pool key
     * @param zeroForOne Swap direction
     * @param amountSpecified Amount to swap (negative for exact input)
     * @param sqrtPriceLimitX96 Price limit
     * @param minAmountOut Minimum output amount before bridge
     * @param bridgeParams Bridge parameters (destination chain, recipient)
     * @return amountOut The output amount sent to bridge
     */
    function swapAndBridge(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 minAmountOut,
        RecorrHookTypes.BridgeParams calldata bridgeParams
    ) external returns (uint256 amountOut) {
        if (address(bridge) == address(0)) revert ZeroAddress();

        // Validate pool uses RecorrHook
        if (address(key.hooks) != address(recorrHook)) {
            revert InvalidPoolHook(address(recorrHook), address(key.hooks));
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BridgeCallbackData memory data = BridgeCallbackData({
            sender: msg.sender,
            key: key,
            params: params,
            bridgeParams: bridgeParams
        });

        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(false, data)), // false = bridge path
            (BalanceDelta)
        );

        int128 deltaAmount = zeroForOne ? delta.amount1() : delta.amount0();
        if (deltaAmount > 0) {
            amountOut = uint256(uint128(deltaAmount));
        }

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        // Determine output token for event logging
        address outputToken = zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        emit SwapAndBridgeExecuted(
            msg.sender,
            key.toId(),
            outputToken, // Use actual output token, not bridgeParams.token
            amountOut,
            bridgeParams.destChainData
        );

        return amountOut;
    }

    // =============================================================
    //                    UNLOCK CALLBACK
    // =============================================================

    /**
     * @notice Callback for PoolManager.unlock()
     * @dev Called by PoolManager during unlock to execute swap and handle settlements
     *      Follows official Uniswap V4 pattern from PoolSwapTest
     * @param rawData Encoded callback data
     * @return Encoded BalanceDelta
     */
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (bool isSwap) = abi.decode(rawData, (bool));

        if (isSwap) {
            (, SwapCallbackData memory cbData) = abi.decode(rawData, (bool, SwapCallbackData));
            return _handleSwapCallback(cbData);
        } else {
            (, BridgeCallbackData memory cbData) = abi.decode(rawData, (bool, BridgeCallbackData));
            return _handleBridgeCallback(cbData);
        }
    }

    /**
     * @notice Handle regular swap callback
     * @dev Uses symmetric settle/take logic like PoolSwapTest
     */
    function _handleSwapCallback(
        SwapCallbackData memory cbData
    ) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.swap(cbData.key, cbData.params, cbData.hookData);

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // Settle negative deltas (user pays) - symmetric for both tokens
        if (amount0 < 0) {
            cbData.key.currency0.settle(
                poolManager,
                cbData.sender,
                uint256(uint128(-amount0)),
                false
            );
        }
        if (amount1 < 0) {
            cbData.key.currency1.settle(
                poolManager,
                cbData.sender,
                uint256(uint128(-amount1)),
                false
            );
        }

        // Take positive deltas (user receives) - symmetric for both tokens
        if (amount0 > 0) {
            cbData.key.currency0.take(
                poolManager,
                cbData.sender,
                uint256(uint128(amount0)),
                false
            );
        }
        if (amount1 > 0) {
            cbData.key.currency1.take(
                poolManager,
                cbData.sender,
                uint256(uint128(amount1)),
                false
            );
        }

        return abi.encode(delta);
    }

    /**
     * @notice Handle swap + bridge callback
     * @dev Settles symmetrically, then takes output to router for bridging
     */
    function _handleBridgeCallback(
        BridgeCallbackData memory cbData
    ) internal returns (bytes memory) {
        // Immediate swap (no async intents for bridge)
        BalanceDelta delta = poolManager.swap(cbData.key, cbData.params, bytes(""));

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // Settle negative deltas from user - symmetric
        if (amount0 < 0) {
            cbData.key.currency0.settle(
                poolManager,
                cbData.sender,
                uint256(uint128(-amount0)),
                false
            );
        }
        if (amount1 < 0) {
            cbData.key.currency1.settle(
                poolManager,
                cbData.sender,
                uint256(uint128(-amount1)),
                false
            );
        }

        // Determine output currency and move it to this contract for bridging
        Currency outputCurrency = cbData.params.zeroForOne
            ? cbData.key.currency1
            : cbData.key.currency0;

        uint256 outputAmount;

        if (cbData.params.zeroForOne && amount1 > 0) {
            outputAmount = uint256(uint128(amount1));
            cbData.key.currency1.take(
                poolManager,
                address(this),
                outputAmount,
                false
            );
        } else if (!cbData.params.zeroForOne && amount0 > 0) {
            outputAmount = uint256(uint128(amount0));
            cbData.key.currency0.take(
                poolManager,
                address(this),
                outputAmount,
                false
            );
        }

        // Bridge the output tokens
        if (outputAmount > 0) {
            address outputToken = Currency.unwrap(outputCurrency);
            IERC20(outputToken).safeIncreaseAllowance(address(bridge), outputAmount);
            bridge.bridge(
                outputToken,
                cbData.bridgeParams.to,
                outputAmount,
                cbData.bridgeParams.destChainData
            );
        }

        return abi.encode(delta);
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Check if a pool is a corridor pool
     * @param key The pool key
     * @return True if pool is designated as corridor
     */
    function isCorridorPool(PoolKey calldata key) external view returns (bool) {
        return recorrHook.isCorridorPool(key.toId());
    }

    /**
     * @notice Get the RecorrHook address
     * @return The hook address
     */
    function getHook() external view returns (address) {
        return address(recorrHook);
    }
}
