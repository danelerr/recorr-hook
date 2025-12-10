// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IMockBridge
 * @notice Interface for mock bridge contract
 * @dev Used by RecorrRouter for Swap & Bridge demo
 */
interface IMockBridge {
    /**
     * @notice Bridge tokens cross-chain
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
    ) external;

    /**
     * @notice Get bridge fee for a token
     * @param token The token to bridge
     * @return The bridge fee amount
     */
    function getBridgeFee(address token) external view returns (uint256);
}
