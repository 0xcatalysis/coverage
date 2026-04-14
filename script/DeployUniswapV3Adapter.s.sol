// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {UniswapV3Adapter} from "../src/swappers/UniswapV3Adapter.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {CreateXDeployer} from "./CreateXDeployer.s.sol";

/**
 * @title DeployUniswapV3Adapter
 * @notice Deploys UniswapV3Adapter via CREATE3 and configures the Swapper for a swap route.
 * @dev Two separate entry-points are used because contract creation requires an EOA (deployer)
 *      while Swapper configuration requires DEFAULT_ADMIN_ROLE / SWAP_MANAGER_ROLE (admin):
 *
 *        run()       — deployer: CREATE3-deploy UniswapV3Adapter
 *        configure() — admin:    setSwapTargetWhitelist + setSwapRoute
 *
 *      On mainnet, admin is a Gnosis Safe multisig that cannot deploy contracts via the `new`
 *      opcode through a Safe transaction. Contract creation MUST originate from the deployer EOA.
 *      After run() completes, submit the configure() calldatas via Safe.
 *
 *      The adapter address is deterministic (depends only on DEPLOYER_ADDRESS + salt) so it can
 *      be precomputed with computeAdapterAddress() before run() is called.
 *
 * Usage — run (testnet, ADMIN == DEPLOYER_ADDRESS):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "run()" --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage — run (mainnet, ADMIN is Gnosis Safe):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "run()" --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage — configure (dry-run to extract calldatas for Safe submission):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "configure()" --rpc-url $RPC_URL \
 *     --sender $ADMIN
 *   (Extract calldatas from broadcast/dry-run JSON and submit via Safe UI)
 *
 * Usage — precompute adapter address:
 *   forge script script/DeployUniswapV3Adapter.s.sol \
 *     --sig "computeAdapterAddress(address)" $DEPLOYER_ADDRESS
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *   - ADMIN: Holder of DEFAULT_ADMIN_ROLE and SWAP_MANAGER_ROLE on Swapper. Defaults to
 *            DEPLOYER_ADDRESS. On mainnet this is the Gnosis Safe multisig — configure()
 *            calldatas must be submitted via Safe after run() completes.
 *   - SWAPPER:       Swapper proxy address (read from ClaimManager.swapper() if unknown)
 *   - SWAP_ROUTER:   Uniswap V3 SwapRouter02 address
 *   - QUOTER_V2:     Uniswap V3 QuoterV2 address
 *   - TOKEN_IN:      Collateral token address
 *   - TOKEN_OUT:     Payout token address
 *   - POOL_FEE:      Uniswap V3 pool fee tier (e.g. 3000 for 0.3%, 500 for 0.05%)
 */
contract DeployUniswapV3Adapter is CreateXDeployer {
    /// @notice Salt label used for the deterministic CREATE3 address.
    string internal constant ADAPTER_SALT = "UniswapV3Adapter";

    // ─── Segment 1: Deploy
    // ──────────────────────────────────────────────────────

    /**
     * @notice Deploys UniswapV3Adapter via CREATE3 for a deterministic address.
     * @dev Must be broadcast from DEPLOYER_ADDRESS (EOA). The deployed address depends only
     *      on DEPLOYER_ADDRESS and the salt — identical across all chains for the same deployer.
     *      Run configure() (or submit its calldatas via Safe) after this step completes.
     */
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address swapper = vm.envAddress("SWAPPER");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address quoter = vm.envAddress("QUOTER_V2");

        console2.log("=== DEPLOY UNISWAP V3 ADAPTER ===");
        console2.log("Deployer:", deployer);
        console2.log("Swapper:", swapper);
        console2.log("SwapRouter:", swapRouter);
        console2.log("QuoterV2:", quoter);
        console2.log("Precomputed adapter address:", computeAdapterAddress(deployer));

        _ensureCreateX();

        vm.startBroadcast(deployer);

        bytes32 salt = _computeSalt(deployer, ADAPTER_SALT);
        bytes memory initCode =
            abi.encodePacked(type(UniswapV3Adapter).creationCode, abi.encode(swapRouter, quoter, swapper));
        address adapter = CREATEX.deployCreate3(salt, initCode);

        vm.stopBroadcast();

        console2.log("UniswapV3Adapter deployed at:", adapter);
        console2.log("\nSet this env var before running configure():");
        console2.log("UNISWAP_V3_ADAPTER=", adapter);
    }

    // ─── Segment 2: Configure
    // ───────────────────────────────────────────────────

    /**
     * @notice Whitelists the adapter in Swapper and sets the tokenIn → tokenOut swap route.
     * @dev Requires DEFAULT_ADMIN_ROLE / SWAP_MANAGER_ROLE on the Swapper contract.
     *      On mainnet, broadcast from ADMIN (Gnosis Safe multisig) — run as a dry-run first
     *      (omit --broadcast) to extract the two calldatas from the dry-run JSON, then submit
     *      each as a separate transaction via the Safe UI.
     *
     *      Required additional env vars:
     *        - UNISWAP_V3_ADAPTER: Address of the adapter deployed in run()
     *        - TOKEN_IN:           Collateral token address
     *        - TOKEN_OUT:          Payout token address
     *        - POOL_FEE:           Uniswap V3 pool fee tier (e.g. 3000)
     */
    function configure() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address admin = vm.envOr("ADMIN", deployer);
        address swapper = vm.envAddress("SWAPPER");
        address adapter = vm.envAddress("UNISWAP_V3_ADAPTER");
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));

        console2.log("=== CONFIGURE UNISWAP V3 ADAPTER ===");
        console2.log("Admin (SWAP_MANAGER_ROLE):", admin);
        console2.log("Swapper:", swapper);
        console2.log("Adapter:", adapter);
        console2.log("TokenIn (collateral):", tokenIn);
        console2.log("TokenOut (payout):", tokenOut);
        console2.log("Pool fee tier:", poolFee);

        vm.startBroadcast(admin);

        ISwapper(swapper).setSwapTargetWhitelist(adapter, true);
        console2.log("Adapter whitelisted in Swapper");

        bytes memory routeCalldata = abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0));
        ISwapper(swapper).setSwapRoute(tokenIn, tokenOut, adapter, true, routeCalldata);
        console2.log("Swap route configured: tokenIn -> tokenOut via adapter");

        vm.stopBroadcast();

        ISwapper.SwapRoute memory route = ISwapper(swapper).getSwapRoute(tokenIn, tokenOut);
        bool whitelisted = ISwapper(swapper).whitelistedTargets(route.swapTarget);
        console2.log("\n=== VERIFICATION ===");
        console2.log("Route enabled:", route.enabled);
        console2.log("Swap target:", route.swapTarget);
        console2.log("Target whitelisted:", whitelisted);
        console2.log("===================");
    }

    // ─── Utility
    // ────────────────────────────────────────────────────────────────

    /**
     * @notice Precomputes the deterministic adapter address for a given deployer.
     * @dev Uses CREATE3 salt derivation — address depends only on deployer + salt, not bytecode.
     *      Call off-chain before run() to know the adapter address in advance.
     * @param deployer Address that will broadcast run().
     * @return The deterministic UniswapV3Adapter address.
     */
    function computeAdapterAddress(address deployer) public pure returns (address) {
        return _computeProxyAddress(deployer, ADAPTER_SALT);
    }
}
