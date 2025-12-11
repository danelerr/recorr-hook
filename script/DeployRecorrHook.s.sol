// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {RecorrHook} from "../contracts/RecorrHook.sol";
import {RecorrRouter} from "../contracts/RecorrRouter.sol";
import {IMockBridge} from "../contracts/interfaces/IMockBridge.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/**
 * @title DeployRecorrHook
 * @notice Production deployment script for RecorrHook + RecorrRouter
 * @dev Handles address mining, deployment, and initial configuration
 * 
 * Usage:
 * 1. Set PRIVATE_KEY in .env
 * 2. Set RPC_URL for target network (Sepolia, Base Sepolia, etc.)
 * 3. Run: forge script script/DeployRecorrHook.s.sol:DeployRecorrHook --rpc-url $RPC_URL --broadcast --verify --via-ir
 * 
 * Networks:
 * - Sepolia: https://sepolia.etherscan.io
 * - Base Sepolia: https://sepolia.basescan.org
 * - Arbitrum Sepolia: https://sepolia.arbiscan.io
 * 
 * Requirements:
 * - PoolManager must be deployed on target network
 * - MockBridge (or real bridge) must be available
 * - Sufficient ETH for deployment (~0.05 ETH recommended)
 */
contract DeployRecorrHook is Script {
    // Expected hook permissions for RecorrHook
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // Network-specific addresses (update per deployment)
    address constant POOL_MANAGER_SEPOLIA = address(0); // Update with actual address
    address constant MOCK_BRIDGE_SEPOLIA = address(0);  // Update with actual address

    function run() public {
        // Load deployer private key from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("\n==============================================");
        console2.log("  RecorrHook Deployment");
        console2.log("  Uniswap Hook Incubator V7");
        console2.log("==============================================\n");
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH\n");

        // Get PoolManager from environment or use default
        address poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER_SEPOLIA);
        address mockBridge = vm.envOr("MOCK_BRIDGE", MOCK_BRIDGE_SEPOLIA);

        require(poolManager != address(0), "PoolManager not configured");
        console2.log("PoolManager:", poolManager);
        console2.log("MockBridge:", mockBridge, "\n");

        // Step 1: Mine hook address with correct flags
        console2.log("--- Step 1: Mining Hook Address ---");
        console2.log("Mining address with flags:", HOOK_FLAGS);
        console2.log("This may take 1-2 minutes...\n");

        vm.startBroadcast(deployerPrivateKey);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            HOOK_FLAGS,
            type(RecorrHook).creationCode,
            abi.encode(IPoolManager(poolManager))
        );

        console2.log("Mined Hook Address:", hookAddress);
        console2.log("Salt:", vm.toString(salt), "\n");

        // Step 2: Deploy RecorrHook
        console2.log("--- Step 2: Deploying RecorrHook ---");
        
        RecorrHook hook = new RecorrHook{salt: salt}(
            IPoolManager(poolManager)
        );

        require(address(hook) == hookAddress, "Hook address mismatch");
        console2.log("RecorrHook deployed at:", address(hook));
        console2.log("Owner:", hook.owner(), "\n");

        // Step 3: Deploy RecorrRouter
        console2.log("--- Step 3: Deploying RecorrRouter ---");
        
        RecorrRouter router = new RecorrRouter(
            IPoolManager(poolManager),
            hook
        );

        console2.log("RecorrRouter deployed at:", address(router));
        
        // Set bridge if configured
        if (mockBridge != address(0)) {
            router.setBridge(IMockBridge(mockBridge));
            console2.log("Bridge configured:", mockBridge);
        } else {
            console2.log("Bridge not configured (can be set later)");
        }
        console2.log("");

        vm.stopBroadcast();

        // Step 4: Print configuration summary
        printDeploymentSummary(address(hook), address(router), poolManager, mockBridge);

        // Step 5: Print next steps
        printNextSteps(address(hook), address(router));
    }

    function printDeploymentSummary(
        address hook,
        address router,
        address poolManager,
        address bridge
    ) internal view {
        console2.log("==============================================");
        console2.log("  DEPLOYMENT SUMMARY");
        console2.log("==============================================\n");
        console2.log("Core Contracts:");
        console2.log("  RecorrHook:   ", hook);
        console2.log("  RecorrRouter: ", router);
        console2.log("");
        console2.log("Dependencies:");
        console2.log("  PoolManager:  ", poolManager);
        console2.log("  Bridge:       ", bridge);
        console2.log("");
        console2.log("Hook Permissions:");
        console2.log("  beforeSwap:   ENABLED");
        console2.log("  afterSwap:    ENABLED");
        console2.log("  (All others:  DISABLED)");
        console2.log("");
        console2.log("Verification Commands:");
        console2.log("  RecorrHook:");
        console2.log("    forge verify-contract ", hook);
        console2.log("      --constructor-args");
        console2.log("      --watch");
        console2.log("");
        console2.log("  RecorrRouter:");
        console2.log("    forge verify-contract ", router);
        console2.log("      --constructor-args");
        console2.log("      --watch\n");
    }

    function printNextSteps(address hook, address router) internal view {
        console2.log("==============================================");
        console2.log("  NEXT STEPS");
        console2.log("==============================================");
        console2.log("1. Setup Corridor Pool:");
        console2.log("   - Call: RecorrHook.setCorridorPool(poolKey, true)");
        console2.log("   - Parameters:");
        console2.log("     * currency0: USDC address");
        console2.log("     * currency1: USDT address");
        console2.log("     * fee: For dynamic fees use LPFeeLibrary.DYNAMIC_FEE_FLAG");
        console2.log("           For static fees use 3000 (0.3%)");
        console2.log("     * tickSpacing: 60");
        console2.log("     * hooks: ", hook);
        console2.log("");
        console2.log("2. Configure Dynamic Fees (Optional):");
        console2.log("   - NOTE: Pool must be created with DYNAMIC_FEE_FLAG");
        console2.log("   - Call: RecorrHook.setPoolFeeParams(poolKey, params)");
        console2.log("   - Recommended params:");
        console2.log("     * baseFee: 500 (0.05%)");
        console2.log("     * maxExtraFee: 2000 (0.2%)");
        console2.log("     * threshold: 10000e18");
        console2.log("");
        console2.log("3. Add Liquidity:");
        console2.log("   - Use PoolManager.modifyLiquidity()");
        console2.log("   - Provide balanced liquidity around 1:1 price");
        console2.log("   - Recommended: +/-1% around current price");
        console2.log("");
        console2.log("4. Create Test Intent:");
        console2.log("   - Use RecorrRouter.swap() with hookData");
        console2.log("   - hookData format (65 bytes):");
        console2.log("     * byte 0: 0x01 (async mode flag)");
        console2.log("     * bytes 1-32: minAmountOut (uint256)");
        console2.log("     * bytes 33-64: deadline (uint48, ABI padded)");
        console2.log("   - IMPORTANT: Use abi.encode for proper padding");
        console2.log("   - Example:");
        console2.log("     bytes memory hookData = abi.encodePacked(");
        console2.log("       uint8(1),");
        console2.log("       abi.encode(");
        console2.log("         uint256(amountIn * 99 / 100),  // minOut");
        console2.log("         uint48(block.timestamp + 3600)  // deadline");
        console2.log("       )");
        console2.log("     );");
        console2.log("");
        console2.log("5. Monitor Intents:");
        console2.log("   - Listen to IntentCreated events");
        console2.log("   - Aggregate opposing intents");
        console2.log("   - Call settleCorridorBatch() when sufficient volume");
        console2.log("");
        console2.log("6. Execute Settlement:");
        console2.log("   - Call: RecorrHook.settleCorridorBatch(intentIds, amountsOut)");
        console2.log("   - intentIds: Array of intent IDs to settle");
        console2.log("   - amountsOut: Expected output for each intent");
        console2.log("   - Monitor CoWExecuted event for stats");
        console2.log("   - Gas savings: ~50k per intent in batch");
        console2.log("");
        console2.log("==============================================");
        console2.log("  Deployment Complete!");
        console2.log("  Save addresses to .env for future reference");
        console2.log("==============================================\n");
    }
}
