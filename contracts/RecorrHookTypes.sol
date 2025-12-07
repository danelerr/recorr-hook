// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title RecorrHookTypes
 * @notice Shared types, structs, and enums for the RecorrHook system
 * @dev Contains all data structures used across RecorrHook contracts
 */
library RecorrHookTypes {
    /// @notice Represents an asynchronous swap intent
    /// @dev Stored on-chain until settled by solver
    struct Intent {
        address owner;              // User who created the intent
        bool zeroForOne;           // Swap direction: true = token0->token1, false = token1->token0
        uint128 amountSpecified;   // Amount of input token
        uint160 sqrtPriceLimitX96; // Price limit in Q64.96 format
        uint256 minOut;            // Minimum output amount (slippage protection)
        uint48 deadline;           // Unix timestamp when intent expires
        bool settled;              // Whether intent has been settled
        PoolId poolId;             // The pool this intent is for
    }

    /// @notice Parameters for dynamic fee calculation
    /// @dev Configured per corridor pool by admin
    struct FeeParams {
        uint24 baseFee;            // Base fee in hundredths of bps (e.g., 500 = 5 bps)
        uint24 maxExtraFee;        // Maximum additional fee when imbalanced
        int256 netFlowThreshold;   // netFlow threshold that triggers extra fees
    }

    /// @notice Parameters for creating a swap through the router
    /// @dev Renamed to avoid confusion with IPoolManager.SwapParams
    struct CorridorSwapParams {
        PoolId poolId;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    /// @notice Parameters for bridging tokens cross-chain
    struct BridgeParams {
        address token;
        address to;
        bytes destChainData;       // Encoded destination chain info
    }

    /// @notice Mode for processing swaps in corridor pools
    enum SwapMode {
        SYNC,                      // Execute swap immediately
        ASYNC                      // Create intent for later settlement
    }

    /// @notice Statistics about a CoW settlement batch
    struct CoWStats {
        uint256 totalZeroForOne;   // Total amount of zeroForOne intents
        uint256 totalOneForZero;   // Total amount of oneForZero intents
        uint256 matchedAmount;     // Amount settled peer-to-peer
        uint256 netAmountToAmm;    // Net amount sent to AMM (fixed naming)
        bool netDirection;         // Direction of net flow (true = zeroForOne)
    }

    // =============================================================
    //                           EVENTS
    // =============================================================

    /// @notice Emitted when a new intent is created
    event IntentCreated(
        uint256 indexed intentId,
        address indexed owner,
        PoolId indexed poolId,
        bool zeroForOne,
        uint128 amountSpecified,
        uint256 minOut,
        uint48 deadline
    );

    /// @notice Emitted when an intent is settled
    event IntentSettled(
        uint256 indexed intentId,
        address indexed owner,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when a batch of intents is settled with CoW
    event CoWExecuted(
        uint256 batchSize,
        uint256 matchedAmount,
        uint256 netAmountToAmm,  // Fixed naming convention
        bool netDirection,
        uint256 gasSaved
    );

    /// @notice Emitted when dynamic fee parameters are updated
    event DynamicFeeUpdated(
        PoolId indexed poolId,
        uint24 baseFee,
        uint24 maxExtraFee,
        int256 netFlowThreshold
    );

    /// @notice Emitted when a corridor pool is registered/unregistered
    event CorridorPoolSet(
        PoolId indexed poolId,
        bool isCorridor
    );

    /// @notice Emitted when netFlow is updated for a pool
    event NetFlowUpdated(
        PoolId indexed poolId,
        int256 oldNetFlow,
        int256 newNetFlow
    );

    /// @notice Emitted when tokens are bridged cross-chain
    event Bridged(
        address indexed token,
        address indexed to,
        uint256 amount,
        bytes destChainData
    );

    // =============================================================
    //                           ERRORS
    // =============================================================

    error IntentExpired(uint256 intentId, uint48 deadline);
    error IntentAlreadySettled(uint256 intentId);
    error IntentNotFound(uint256 intentId);
    error InvalidDeadline(uint48 deadline);
    error MinOutputNotMet(uint256 expected, uint256 actual);
    error NotCorridorPool(PoolId poolId);
    error InvalidFeeParams();
    error Unauthorized();
    error InvalidSwapMode();
    error ZeroAddress();
    error ZeroAmount();
}
