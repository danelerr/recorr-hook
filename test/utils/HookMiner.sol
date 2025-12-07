// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/**
 * @title HookMiner
 * @notice Library for mining hook addresses with correct permission bits
 * @dev Follows official Uniswap v4 pattern for CREATE2 address mining
 */
library HookMiner {
    /**
     * @notice Find a salt that produces a hook address with the correct permission bits
     * @dev Uses CREATE2 to compute addresses and checks against ALL_HOOK_MASK for exact match
     * @param deployer The address that will deploy the hook contract
     * @param flags The hook permission flags encoded as uint160 (lower 14 bits)
     * @param creationCode The contract creation bytecode
     * @param constructorArgs The encoded constructor arguments
     * @return hookAddress The computed address with correct permission bits
     * @return salt The salt value that produces the correct address
     */
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);
        
        // Try salts until we find one that works (up to 100k iterations)
        for (uint256 i = 0; i < 100_000; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);
            
            // Check that the lower 14 bits match exactly (no extra bits set)
            if ((uint160(hookAddress) & Hooks.ALL_HOOK_MASK) == flags) {
                return (hookAddress, salt);
            }
        }
        
        revert("HookMiner: could not find salt");
    }

    /**
     * @notice Compute the CREATE2 address
     * @param deployer The deployer address
     * @param salt The salt
     * @param creationCode The creation code
     * @return The computed address
     */
    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes memory creationCode
    ) internal pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                deployer,
                salt,
                keccak256(creationCode)
            )
        );
        
        return address(uint160(uint256(hash)));
    }
}
