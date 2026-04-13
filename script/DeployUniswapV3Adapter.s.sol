// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniswapV3Adapter} from "../src/swappers/UniswapV3Adapter.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";

/**
 * @title DeployUniswapV3Adapter
 * @notice Deploys UniswapV3Adapter and configures the Swapper for a collateral -> payout token swap route.
 * @dev Two separate broadcast segments are used because contract creation requires an EOA (deployer)
 *      while Swapper configuration requires DEFAULT_ADMIN_ROLE / SWAP_MANAGER_ROLE (admin):
 *
 *        Segment 1 — deployer: new UniswapV3Adapter(...)
 *        Segment 2 — admin:    setSwapTargetWhitelist + setSwapRoute
 *
 *      On mainnet, admin is a Gnosis Safe multisig that cannot deploy contracts via the `new`
 *      opcode through a Safe transaction. Contract creation MUST originate from the deployer EOA.
 *
 * Usage (testnet — ADMIN == DEPLOYER_ADDRESS):
 *   forge script script/DeployUniswapV3Adapter.s.sol --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage (mainnet — ADMIN is a Gnosis Safe multisig):
 *   forge script script/DeployUniswapV3Adapter.s.sol --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *   (deployer keystore signs Segment 1; Segment 2 calldatas are printed for Safe submission)
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *   - ADMIN: Holder of DEFAULT_ADMIN_ROLE and SWAP_MANAGER_ROLE on Swapper. Defaults to
 *            DEPLOYER_ADDRESS. On mainnet this is the Gnosis Safe multisig — Segment 2
 *            calldatas must be submitted via Safe after the adapter address is known.
 *   - SWAPPER:       Swapper proxy address (read from ClaimManager.swapper() if unknown)
 *   - SWAP_ROUTER:   Uniswap V3 SwapRouter02 address
 *   - QUOTER_V2:     Uniswap V3 QuoterV2 address
 *   - TOKEN_IN:      Collateral token address
 *   - TOKEN_OUT:     Payout token address
 *   - POOL_FEE:      Uniswap V3 pool fee tier (e.g. 3000 for 0.3%, 500 for 0.05%)
 */
contract DeployUniswapV3Adapter is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        // DEFAULT_ADMIN_ROLE and SWAP_MANAGER_ROLE are held by ADMIN after coverage deploy.
        // On mainnet ADMIN is the multisig; Segment 2 calldatas must be submitted via Safe.
        address admin = vm.envOr("ADMIN", deployer);

        address swapper = vm.envAddress("SWAPPER");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address quoter = vm.envAddress("QUOTER_V2");
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));

        console.log("=== DEPLOY UNISWAP V3 ADAPTER ===");
        console.log("Deployer (contract creation):", deployer);
        console.log("Admin (Swapper config):      ", admin);
        console.log("Swapper:", swapper);
        console.log("SwapRouter:", swapRouter);
        console.log("TokenIn (collateral):", tokenIn);
        console.log("TokenOut (payout):", tokenOut);
        console.log("Pool fee tier:", poolFee);

        // ── Segment 1: Deploy adapter (must originate from an EOA, not a Safe) ──────
        vm.startBroadcast(deployer);
        UniswapV3Adapter adapter = new UniswapV3Adapter(swapRouter, quoter, swapper);
        vm.stopBroadcast();
        console.log("UniswapV3Adapter deployed at:", address(adapter));

        // ── Segment 2: Configure Swapper (requires DEFAULT_ADMIN_ROLE / SWAP_MANAGER_ROLE) ──
        // On mainnet, admin is the multisig — this segment's calldatas are submitted via Safe.
        vm.startBroadcast(admin);

        ISwapper(swapper).setSwapTargetWhitelist(address(adapter), true);
        console.log("Adapter whitelisted in Swapper");

        bytes memory routeCalldata = abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0));
        ISwapper(swapper).setSwapRoute(tokenIn, tokenOut, address(adapter), true, routeCalldata);
        console.log("Swap route configured: tokenIn -> tokenOut via adapter");

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
