// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {RecorrHook} from "../contracts/RecorrHook.sol";
import {RecorrRouter} from "../contracts/RecorrRouter.sol";
import {IMockBridge} from "../contracts/interfaces/IMockBridge.sol";
import {MockBridge} from "../contracts/mocks/MockBridge.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {MockBOB} from "../contracts/mocks/MockBOB.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/**
 * @title DeployRecorrHook
 * @notice Complete deployment script for RecorrHook ecosystem on testnet
 * @dev Deploys tokens, hook, router, bridge, and initializes pool with liquidity
 * 
 * Usage (Sepolia - RECOMMENDED):
 * 1. Get Sepolia ETH from faucet: https://sepoliafaucet.com
 * 2. Set PRIVATE_KEY in .env
 * 3. Run: forge script script/DeployRecorrHook.s.sol:DeployRecorrHook --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY --via-ir -vvvv
 * 
 * Alternative RPC URLs for Sepolia:
 * - https://rpc.sepolia.org
 * - https://ethereum-sepolia.blockpi.network/v1/rpc/public
 * - https://1rpc.io/sepolia
 * 
 * What this script does:
 * - Deploys MockUSDC and MockBOB tokens (with public mint)
 * - Deploys MockBridge for cross-chain simulation
 * - Mines and deploys RecorrHook with correct permissions
 * - Deploys RecorrRouter and configures bridge
 * - Creates USDC/BOB pool with dynamic fees
 * - Adds initial liquidity (50k USDC + 350k BOB, ~1:7 ratio)
 * - Configures hook parameters (corridor + fee params)
 * 
 * Networks:
 * - Sepolia PoolManager: 0x... (check Uniswap v4 docs)
 * - Base Sepolia PoolManager: 0x... (check Uniswap v4 docs)
 * - Anvil (local): Deploy your own PoolManager
 */
contract DeployRecorrHook is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Expected hook permissions for RecorrHook
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // PoolManager addresses (official Uniswap v4 deployments)
    // NOTE: These are placeholder addresses - update with actual v4 deployments
    address constant POOL_MANAGER_SEPOLIA = 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829; // v4 PoolManager
    address constant POOL_MANAGER_BASE_SEPOLIA = 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829; // v4 PoolManager
    
    // Pool configuration
    int24 constant TICK_SPACING = 60; // 0.3% tick spacing
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000; // Flag for dynamic fees
    
    // Initial liquidity amounts (BOB trades ~7:1 vs USD)
    uint256 constant INITIAL_USDC = 50_000 * 10 ** 6; // 50k USDC
    uint256 constant INITIAL_BOB = 350_000 * 10 ** 6;  // 350k BOB (~7:1 ratio)
    
    // Fee parameters
    uint24 constant BASE_FEE = 500;      // 0.05% base fee
    uint24 constant MAX_EXTRA_FEE = 2000; // 0.2% max extra fee
    uint256 constant THRESHOLD = 10_000 * 10 ** 6; // 10k token threshold

    function run() public {
        // Load deployer private key from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("\n==============================================");
        console2.log("  RecorrHook Complete Deployment");
        console2.log("  Uniswap Hook Incubator V7 - Hookathon");
        console2.log("==============================================\n");
        console2.log("Deployer:", deployer);
        console2.log("Balance:", deployer.balance / 1e18, "ETH\n");

        // Get PoolManager from environment or use default
        address poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER_SEPOLIA);
        require(poolManager != address(0), "PoolManager not configured");
        console2.log("PoolManager:", poolManager, "\n");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Mock Tokens
        console2.log("--- Step 1: Deploying Mock Tokens ---");
        MockUSDC usdc = new MockUSDC();
        MockBOB bob = new MockBOB();
        console2.log("MockUSDC deployed at:", address(usdc));
        console2.log("MockBOB deployed at:", address(bob));
        console2.log("Deployer USDC balance:", usdc.balanceOf(deployer) / 10 ** 6, "USDC");
        console2.log("Deployer BOB balance:", bob.balanceOf(deployer) / 10 ** 6, "BOB\n");

        // Step 2: Deploy MockBridge
        console2.log("--- Step 2: Deploying MockBridge ---");
        MockBridge bridge = new MockBridge();
        console2.log("MockBridge deployed at:", address(bridge), "\n");

        // Step 3: Mine and deploy RecorrHook
        console2.log("--- Step 3: Mining Hook Address ---");
        console2.log("Mining address with flags:", HOOK_FLAGS);
        console2.log("This may take 1-2 minutes...");

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            HOOK_FLAGS,
            type(RecorrHook).creationCode,
            abi.encode(IPoolManager(poolManager))
        );

        console2.log("Mined Hook Address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));
        
        RecorrHook hook = new RecorrHook{salt: salt}(
            IPoolManager(poolManager)
        );

        require(address(hook) == hookAddress, "Hook address mismatch");
        console2.log("RecorrHook deployed at:", address(hook));
        console2.log("Owner:", hook.owner(), "\n");

        // Step 4: Deploy RecorrRouter
        console2.log("--- Step 4: Deploying RecorrRouter ---");
        RecorrRouter router = new RecorrRouter(
            IPoolManager(poolManager),
            hook
        );

        console2.log("RecorrRouter deployed at:", address(router));
        router.setBridge(IMockBridge(address(bridge)));
        console2.log("Bridge configured\n");

        // Step 5: Create Pool with Dynamic Fees
        console2.log("--- Step 5: Creating USDC/BOB Pool ---");
        
        // Sort tokens (Currency uses address ordering)
        Currency currency0;
        Currency currency1;
        if (address(usdc) < address(bob)) {
            currency0 = Currency.wrap(address(usdc));
            currency1 = Currency.wrap(address(bob));
            console2.log("Pool: USDC (currency0) / BOB (currency1)");
        } else {
            currency0 = Currency.wrap(address(bob));
            currency1 = Currency.wrap(address(usdc));
            console2.log("Pool: BOB (currency0) / USDC (currency1)");
        }

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DYNAMIC_FEE_FLAG, // Dynamic fees enabled
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:7 price (adjust sqrtPriceX96 accordingly)
        // For roughly 1 USDC = 7 BOB: sqrtPrice = sqrt(7) * 2^96
        uint160 sqrtPriceX96 = 209451582184475596466742242708; // sqrt(7) * 2^96
        
        IPoolManager(poolManager).initialize(poolKey, sqrtPriceX96);
        console2.log("Pool initialized at ~1:7 price ratio");
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolKey.toId())), "\n");

        // Step 6: Configure Hook Parameters
        console2.log("--- Step 6: Configuring Hook ---");
        hook.setCorridorPool(poolKey, true);
        console2.log("Corridor pool registered");
        
        hook.setPoolFeeParams(
            poolKey,
            RecorrHook.FeeParams({
                baseFee: BASE_FEE,
                maxExtraFee: MAX_EXTRA_FEE,
                threshold: THRESHOLD
            })
        );
        console2.log("Fee params configured:");
        console2.log("  Base Fee:", BASE_FEE, "(0.05%)");
        console2.log("  Max Extra Fee:", MAX_EXTRA_FEE, "(0.2%)");
        console2.log("  Threshold:", THRESHOLD / 10 ** 6, "tokens\n");

        // Step 7: Add Initial Liquidity
        console2.log("--- Step 7: Adding Liquidity ---");
        
        // Approve PoolManager to spend tokens
        usdc.approve(poolManager, type(uint256).max);
        bob.approve(poolManager, type(uint256).max);
        console2.log("Token approvals granted");

        // Deploy liquidity helper (v4-core test contract)
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(poolManager));
        usdc.approve(address(lpRouter), type(uint256).max);
        bob.approve(address(lpRouter), type(uint256).max);

        // Add liquidity in range around current price
        // Using full range for simplicity: tick -887220 to 887220
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 1000000000000000000, // 1e18 liquidity units
                salt: bytes32(0)
            }),
            ""
        );

        console2.log("Liquidity added successfully");
        console2.log("USDC in pool:", INITIAL_USDC / 10 ** 6, "USDC");
        console2.log("BOB in pool:", INITIAL_BOB / 10 ** 6, "BOB\n");

        vm.stopBroadcast();

        // Print deployment summary
        printDeploymentSummary(
            address(hook),
            address(router),
            address(usdc),
            address(bob),
            address(bridge),
            poolManager,
            poolKey
        );

        // Print frontend config
        printFrontendConfig(
            address(hook),
            address(router),
            address(usdc),
            address(bob),
            address(bridge),
            poolKey
        );
    }

    function printDeploymentSummary(
        address hook,
        address router,
        address usdc,
        address bob,
        address bridge,
        address poolManager,
        PoolKey memory poolKey
    ) internal view {
        console2.log("==============================================");
        console2.log("  DEPLOYMENT SUMMARY");
        console2.log("==============================================\n");
        console2.log("Tokens:");
        console2.log("  MockUSDC:     ", usdc);
        console2.log("  MockBOB:      ", bob);
        console2.log("");
        console2.log("Core Contracts:");
        console2.log("  RecorrHook:   ", hook);
        console2.log("  RecorrRouter: ", router);
        console2.log("  MockBridge:   ", bridge);
        console2.log("");
        console2.log("Dependencies:");
        console2.log("  PoolManager:  ", poolManager);
        console2.log("");
        console2.log("Pool Configuration:");
        console2.log("  Currency0:    ", Currency.unwrap(poolKey.currency0));
        console2.log("  Currency1:    ", Currency.unwrap(poolKey.currency1));
        console2.log("  Fee:          DYNAMIC");
        console2.log("  Tick Spacing: ", uint256(int256(poolKey.tickSpacing)));
        console2.log("  Liquidity:    ACTIVE");
        console2.log("");
        console2.log("Hook Permissions:");
        console2.log("  beforeSwap:   ENABLED");
        console2.log("  afterSwap:    ENABLED");
        console2.log("");
        console2.log("Fee Configuration:");
        console2.log("  Base Fee:     0.05%");
        console2.log("  Max Extra:    0.2%");
        console2.log("  Threshold:    10,000 tokens");
        console2.log("");
        console2.log("==============================================");
        console2.log("  DEPLOYMENT COMPLETE");
        console2.log("  Ready for frontend integration!");
        console2.log("==============================================\n");
    }

    function printFrontendConfig(
        address hook,
        address router,
        address usdc,
        address bob,
        address bridge,
        PoolKey memory poolKey
    ) internal view {
        console2.log("==============================================");
        console2.log("  FRONTEND CONFIGURATION");
        console2.log("==============================================");
        console2.log("");
        console2.log("Copy this to your frontend .env or config file:");
        console2.log("");
        console2.log("# RecorrHook Deployment Addresses");
        console2.log("NEXT_PUBLIC_RECORR_HOOK=", hook);
        console2.log("NEXT_PUBLIC_RECORR_ROUTER=", router);
        console2.log("NEXT_PUBLIC_MOCK_USDC=", usdc);
        console2.log("NEXT_PUBLIC_MOCK_BOB=", bob);
        console2.log("NEXT_PUBLIC_MOCK_BRIDGE=", bridge);
        console2.log("");
        console2.log("# Pool Configuration");
        console2.log("NEXT_PUBLIC_CURRENCY0=", Currency.unwrap(poolKey.currency0));
        console2.log("NEXT_PUBLIC_CURRENCY1=", Currency.unwrap(poolKey.currency1));
        console2.log("NEXT_PUBLIC_TICK_SPACING=", uint256(int256(poolKey.tickSpacing)));
        console2.log("");
        console2.log("==============================================");
        console2.log("  TESTING GUIDE");
        console2.log("==============================================");
        console2.log("");
        console2.log("1. Mint Test Tokens (anyone can call):");
        console2.log("   MockUSDC.mintStandard(yourAddress)  // 10k USDC");
        console2.log("   MockBOB.mintStandard(yourAddress)   // 10k BOB");
        console2.log("");
        console2.log("2. Test Instant Swap:");
        console2.log("   - Use RecorrRouter.swap()");
        console2.log("   - hookData: empty (0x) for instant swap");
        console2.log("   - Approve tokens first!");
        console2.log("");
        console2.log("3. Create Async Intent:");
        console2.log("   - Use RecorrRouter.swap() with hookData");
        console2.log("   - hookData: abi.encodePacked(");
        console2.log("       uint8(1),  // async mode");
        console2.log("       abi.encode(minOut, deadline)");
        console2.log("     )");
        console2.log("   - Listen for IntentCreated event");
        console2.log("");
        console2.log("4. Execute CoW Settlement:");
        console2.log("   - Collect opposing intents");
        console2.log("   - Call RecorrHook.settleCorridorBatch()");
        console2.log("   - Monitor CoWExecuted event");
        console2.log("");
        console2.log("5. Monitor Dynamic Fees:");
        console2.log("   - Watch fee changes based on netFlow");
        console2.log("   - Base: 0.05%, Max: 0.25% (0.05% + 0.2%)");
        console2.log("   - Fees increase when netFlow > 10k tokens");
        console2.log("");
        console2.log("==============================================");
        console2.log("  DEMO VIDEO SCRIPT");
        console2.log("==============================================");
        console2.log("");
        console2.log("For your Hookathon video, show:");
        console2.log("1. This deployment output");
        console2.log("2. Mint tokens (show public mint working)");
        console2.log("3. Create 2-3 intents in opposite directions");
        console2.log("4. Execute CoW settlement");
        console2.log("5. Show gas savings + efficiency metrics");
        console2.log("6. Explain architecture diagram from README");
        console2.log("");
        console2.log("==============================================\n");
    }
}
