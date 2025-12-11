// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

/**
 * @title MockBOB
 * @notice Mock BOB (Boliviano) token for testnet deployment
 * @dev 6 decimals for consistency with USDC, with public mint for testing
 */
contract MockBOB is ERC20, Owned {
    constructor() ERC20("Mock Boliviano", "BOB", 6) Owned(msg.sender) {
        // Mint initial supply to deployer (1M BOB)
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }

    /**
     * @notice Public mint function for testnet users
     * @dev Anyone can mint tokens for testing
     * @param to Address to receive tokens
     * @param amount Amount to mint (in wei, 6 decimals)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Convenience function to mint standard amounts
     * @param to Address to receive tokens
     */
    function mintStandard(address to) external {
        // Mint 10,000 BOB (~$1,400 USD at ~7 BOB/USD)
        _mint(to, 10_000 * 10 ** 6);
    }

    /**
     * @notice Faucet function for frontend integration
     * @dev Mints a fixed amount to caller - perfect for "Get Test Tokens" button
     * Anyone can call this to get tokens for testing
     */
    function faucet() external {
        // Mint 10,000 BOB to caller
        _mint(msg.sender, 10_000 * 10 ** 6);
    }

    /**
     * @notice Owner-only mint function to increase supply
     * @dev Use this if faucet tokens run out or you need to fund specific addresses
     * @param to Address to receive tokens
     * @param amount Amount to mint (in wei, 6 decimals)
     */
    function ownerMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Convenience function for owner to mint large amounts
     * @dev Useful for refilling pool liquidity or creating reserves
     * @param to Address to receive tokens
     */
    function ownerMintBatch(address to) external onlyOwner {
        // Mint 1M BOB at once
        _mint(to, 1_000_000 * 10 ** 6);
    }
}
