// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";

/**
 * @title DeployUniswapV3Adapter
 * @notice Deploys UniswapV3Adapter and configures the Swapper for a WETH -> USDC swap route.
 * @dev Run on Sepolia:
 *      forge script script/DeployUniswapV3Adapter.s.sol --rpc-url $SEPOLIA_RPC_URL \
 *        --private-key $PRIVATE_KEY --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/admin private key (must hold DEFAULT_ADMIN_ROLE and SWAP_MANAGER_ROLE on Swapper)
 *   - SWAPPER: Swapper proxy address (read from ClaimManager.swapper() if unknown)
 *   - SWAP_ROUTER: Uniswap V3 SwapRouter02 address
 *                  Sepolia default: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
 *   - QUOTER: Uniswap V3 QuoterV2 address
 *   - ADAPTER_OWNER: Address that will own the adapter (for setPairFee); defaults to deployer
 *   - TOKEN_IN: Collateral token address (e.g. Uniswap-native WETH on Sepolia:
 * 0xfff9976782d46cc05630d1f6ebab18b2324d6b14)
 *   - TOKEN_OUT: Payout token address (e.g. Circle Sepolia USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
 *   - POOL_FEE: Uniswap V3 pool fee tier (e.g. 3000 for 0.3%, 500 for 0.05%)
 */
contract DeployUniswapV3Adapter is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address swapper = vm.envAddress("SWAPPER");
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E));
        address quoter = vm.envAddress("QUOTER");
        address adapterOwner = vm.envOr("ADAPTER_OWNER", deployer);
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));

        console.log("=== DEPLOY UNISWAP V3 ADAPTER ===");
        console.log("Deployer:", deployer);
        console.log("Swapper:", swapper);
        console.log("SwapRouter:", swapRouter);
        console.log("Quoter:", quoter);
        console.log("Adapter owner:", adapterOwner);
        console.log("TokenIn (collateral):", tokenIn);
        console.log("TokenOut (payout):", tokenOut);
        console.log("Pool fee tier:", poolFee);

        vm.startBroadcast(deployerKey);

        UniswapV3Adapter adapter = new UniswapV3Adapter(swapRouter, swapper, quoter, adapterOwner);
        console.log("UniswapV3Adapter deployed at:", address(adapter));

        ISwapper(swapper).setSwapTargetWhitelist(address(adapter), true);
        console.log("Adapter whitelisted in Swapper");

        bytes memory routeCalldata = abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0));
        ISwapper(swapper).setSwapRoute(tokenIn, tokenOut, address(adapter), true, routeCalldata);
        console.log("Swap route configured: tokenIn -> tokenOut via adapter");

        // Sync the quoting fee with the swap fee so Swapper.quoteSwap returns estimates
        // from the same pool that will be used for execution.
        adapter.setPairFee(tokenIn, tokenOut, poolFee);
        console.log("Quote fee synced to pool fee tier:", poolFee);

        vm.stopBroadcast();

        ISwapper.SwapRoute memory route = ISwapper(swapper).getSwapRoute(tokenIn, tokenOut);
        bool whitelisted = ISwapper(swapper).whitelistedTargets(route.swapTarget);
        console.log("\n=== VERIFICATION ===");
        console.log("Route enabled:", route.enabled);
        console.log("Swap target:", route.swapTarget);
        console.log("Target whitelisted:", whitelisted);
        console.log("===================");
        console.log("\nSet this env var for testing scripts:");
        console.log("UNISWAP_V3_ADAPTER=", address(adapter));
    }
}
