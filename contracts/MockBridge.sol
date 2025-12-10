// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMockBridge} from "./interfaces/IMockBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockBridge
 * @notice Mock bridge contract for demo/testing
 * @dev Simulates cross-chain bridging for RecorrRouter demo
 * 
 * In production, this would integrate with:
 * - LayerZero, Wormhole, Axelar, etc.
 * - Native bridge protocols
 * - Or custom bridge infrastructure
 * 
 * This mock simply:
 * - Burns/locks tokens
 * - Emits events for off-chain relayers
 * - Tracks bridge metrics
 * 
 * @custom:security NOT FOR PRODUCTION - demo purposes only
 */
contract MockBridge is IMockBridge {
    using SafeERC20 for IERC20;

    // =============================================================
    //                       STATE VARIABLES
    // =============================================================

    /// @notice Bridge fee per token (basis points)
    mapping(address => uint256) public bridgeFees;

    /// @notice Total volume bridged per token
    mapping(address => uint256) public totalBridged;

    /// @notice Default bridge fee (10 bps = 0.1%)
    uint256 public constant DEFAULT_FEE_BPS = 10;

    /// @notice Max bridge fee allowed (100 bps = 1%)
    uint256 public constant MAX_FEE_BPS = 100;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event BridgeInitiated(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        bytes destChainData,
        uint256 timestamp
    );

    event BridgeFeeUpdated(
        address indexed token,
        uint256 oldFee,
        uint256 newFee
    );

    // =============================================================
    //                           ERRORS
    // =============================================================

    error InsufficientAmount();
    error FeeTooHigh();
    error ZeroAddress();

    // =============================================================
    //                      BRIDGE FUNCTIONS
    // =============================================================

    /**
     * @notice Bridge tokens cross-chain
     * @dev Mock implementation - just locks tokens and emits event
     * @param token The token to bridge
     * @param to The recipient address on destination chain
     * @param amount The amount to bridge
     * @param destChainData Encoded destination chain info
     */
    function bridge(
        address token,
        address to,
        uint256 amount,
        bytes calldata destChainData
    ) external override {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InsufficientAmount();

        // Calculate fee
        uint256 fee = getBridgeFee(token);
        uint256 feeAmount = (amount * fee) / 10000;
        uint256 netAmount = amount - feeAmount;

        // Transfer tokens from caller (usually RecorrRouter)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update metrics
        totalBridged[token] += netAmount;

        // Emit event for off-chain relayers
        emit BridgeInitiated(
            token,
            msg.sender,
            to,
            netAmount,
            feeAmount,
            destChainData,
            block.timestamp
        );

        // In production:
        // - Call external bridge protocol
        // - Lock tokens in escrow
        // - Emit cross-chain message
        // - Handle bridge confirmation
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Set bridge fee for a specific token
     * @dev In production, add access control
     * @param token The token address
     * @param feeBps Fee in basis points (100 = 1%)
     */
    function setBridgeFee(address token, uint256 feeBps) external {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        
        uint256 oldFee = bridgeFees[token];
        bridgeFees[token] = feeBps;
        
        emit BridgeFeeUpdated(token, oldFee, feeBps);
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get bridge fee for a token
     * @param token The token address
     * @return The bridge fee in basis points
     */
    function getBridgeFee(address token) public view override returns (uint256) {
        uint256 fee = bridgeFees[token];
        return fee == 0 ? DEFAULT_FEE_BPS : fee;
    }

    /**
     * @notice Get total bridged volume for a token
     * @param token The token address
     * @return The total amount bridged
     */
    function getTotalBridged(address token) external view returns (uint256) {
        return totalBridged[token];
    }
}
