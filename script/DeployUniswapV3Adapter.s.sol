// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UniswapV3Adapter} from "../src/swappers/UniswapV3Adapter.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {CreateXDeployer} from "./CreateXDeployer.s.sol";

/**
 * @title DeployUniswapV3Adapter
 * @notice Deploys UniswapV3Adapter via CREATE3 and configures the Swapper for a swap route.
 * @dev Two separate entry-points are used because contract creation requires an EOA (deployer)
 *      while Swapper configuration requires privileged roles (admin):
 *
 *        run()       - deployer: CREATE3-deploy UniswapV3Adapter
 *        configure() - admin:    setSwapTargetWhitelist + setSwapRoute
 *
 *      On mainnet, admin is a Gnosis Safe multisig that cannot deploy contracts via the `new`
 *      opcode through a Safe transaction. Contract creation MUST originate from the deployer EOA.
 *
 *      When TIMELOCK is set (mainnet), DEFAULT_ADMIN_ROLE on Swapper is held by the
 *      TimelockController. configure() then:
 *        - Logs schedule/execute calldata for setSwapTargetWhitelist (must go through timelock)
 *        - Broadcasts setSwapRoute directly from admin (uses SWAP_MANAGER_ROLE, not timelock)
 *      When TIMELOCK is not set (testnet), both calls broadcast directly from admin.
 *
 *      The adapter address is deterministic (depends only on DEPLOYER_ADDRESS + salt) so it can
 *      be precomputed with computeAdapterAddress() before run() is called.
 *
 * Usage - run (testnet, ADMIN == DEPLOYER_ADDRESS):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "run()" --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage - run (mainnet, ADMIN is Gnosis Safe):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "run()" --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage - configure (testnet, no timelock):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "configure()" --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage - configure (mainnet, TIMELOCK set):
 *   forge script script/DeployUniswapV3Adapter.s.sol --sig "configure()" --rpc-url $RPC_URL \
 *     --broadcast --slow -vvvv --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *   (Step 1: script logs schedule calldata -- submit to TimelockController via Safe TX Builder)
 *   (Step 2: after delay, script logs execute calldata -- submit to TimelockController via Safe)
 *   (setSwapRoute is broadcast directly in the same run since admin holds SWAP_MANAGER_ROLE)
 *
 * Usage - precompute adapter address:
 *   forge script script/DeployUniswapV3Adapter.s.sol \
 *     --sig "computeAdapterAddress(address)" $DEPLOYER_ADDRESS
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *   - ADMIN: Holder of SWAP_MANAGER_ROLE on Swapper. Defaults to DEPLOYER_ADDRESS.
 *            On mainnet this is the Gnosis Safe multisig.
 *   - TIMELOCK (optional): TimelockController address. When set, setSwapTargetWhitelist is
 *            routed through the timelock (calldata logged); setSwapRoute is broadcast directly.
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

    // --- Segment 1: Deploy -------------------------------------------------------

    /**
     * @notice Deploys UniswapV3Adapter via CREATE3 for a deterministic address.
     * @dev Must be broadcast from DEPLOYER_ADDRESS (EOA). The deployed address depends only
     *      on DEPLOYER_ADDRESS and the salt - identical across all chains for the same deployer.
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

    // --- Segment 2: Configure ----------------------------------------------------

    /**
     * @notice Whitelists the adapter in Swapper and sets the tokenIn -> tokenOut swap route.
     * @dev setSwapTargetWhitelist requires DEFAULT_ADMIN_ROLE; setSwapRoute requires
     *      SWAP_MANAGER_ROLE. When TIMELOCK is set, DEFAULT_ADMIN_ROLE is held by the
     *      TimelockController, so the whitelist call must be scheduled through it. The
     *      swap route call uses SWAP_MANAGER_ROLE (held directly by admin) and broadcasts
     *      immediately in both modes.
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
        address timelock = vm.envOr("TIMELOCK", address(0));
        address swapper = vm.envAddress("SWAPPER");
        address adapter = vm.envAddress("UNISWAP_V3_ADAPTER");
        address tokenIn = vm.envAddress("TOKEN_IN");
        address tokenOut = vm.envAddress("TOKEN_OUT");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));

        bytes memory routeCalldata = abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0));

        console2.log("=== CONFIGURE UNISWAP V3 ADAPTER ===");
        console2.log("Admin (SWAP_MANAGER_ROLE):", admin);
        console2.log("Swapper:", swapper);
        console2.log("Adapter:", adapter);
        console2.log("TokenIn (collateral):", tokenIn);
        console2.log("TokenOut (payout):", tokenOut);
        console2.log("Pool fee tier:", poolFee);

        if (timelock != address(0)) {
            _configureViaTimelock(admin, timelock, swapper, adapter, tokenIn, tokenOut, routeCalldata);
        } else {
            _configureDirect(admin, swapper, adapter, tokenIn, tokenOut, routeCalldata);
        }

        ISwapper.SwapRoute memory route = ISwapper(swapper).getSwapRoute(tokenIn, tokenOut);
        bool whitelisted = ISwapper(swapper).whitelistedTargets(route.swapTarget);
        console2.log("\n=== VERIFICATION ===");
        console2.log("Route enabled:", route.enabled);
        console2.log("Swap target:", route.swapTarget);
        console2.log("Target whitelisted:", whitelisted);
        console2.log("===================");
    }

    /**
     * @notice Direct configuration path (testnet / no timelock).
     * @dev admin holds DEFAULT_ADMIN_ROLE directly; both calls broadcast immediately.
     */
    function _configureDirect(
        address admin,
        address swapper,
        address adapter,
        address tokenIn,
        address tokenOut,
        bytes memory routeCalldata
    )
        private
    {
        require(IAccessControl(swapper).hasRole(bytes32(0), admin), "ADMIN must have DEFAULT_ADMIN_ROLE on Swapper");

        vm.startBroadcast(admin);
        ISwapper(swapper).setSwapTargetWhitelist(adapter, true);
        console2.log("Adapter whitelisted in Swapper");
        ISwapper(swapper).setSwapRoute(tokenIn, tokenOut, adapter, true, routeCalldata);
        console2.log("Swap route configured: tokenIn -> tokenOut via adapter");
        vm.stopBroadcast();
    }

    /**
     * @notice Timelock configuration path (mainnet).
     * @dev setSwapTargetWhitelist (DEFAULT_ADMIN_ROLE) must go through TimelockController.
     *      Logs schedule/execute calldata for submission via Safe TX Builder.
     *      setSwapRoute (SWAP_MANAGER_ROLE) is broadcast directly from admin.
     */
    function _configureViaTimelock(
        address admin,
        address timelock,
        address swapper,
        address adapter,
        address tokenIn,
        address tokenOut,
        bytes memory routeCalldata
    )
        private
    {
        require(
            IAccessControl(swapper).hasRole(bytes32(0), timelock), "TIMELOCK must have DEFAULT_ADMIN_ROLE on Swapper"
        );

        // Build whitelist calldata for the timelock to execute on the Swapper
        bytes memory whitelistCalldata = abi.encodeCall(ISwapper.setSwapTargetWhitelist, (adapter, true));
        uint256 minDelay = TimelockController(payable(timelock)).getMinDelay();

        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule, (swapper, 0, whitelistCalldata, bytes32(0), bytes32(0), minDelay)
        );
        bytes memory executeCalldata =
            abi.encodeCall(TimelockController.execute, (swapper, 0, whitelistCalldata, bytes32(0), bytes32(0)));

        console2.log("");
        console2.log("--- Timelock Calldata for setSwapTargetWhitelist (submit via Safe TX Builder) ---");
        console2.log("TimelockController:", timelock);
        console2.log("Min Delay:", minDelay, "seconds");
        console2.log("");
        console2.log("Step 1 - Schedule (submit now):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(scheduleCalldata));
        console2.log("");
        console2.log("Step 2 - Execute (submit after delay):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(executeCalldata));
        console2.log("=============================================================================");

        // setSwapRoute uses SWAP_MANAGER_ROLE - admin holds this directly, no timelock needed
        vm.startBroadcast(admin);
        ISwapper(swapper).setSwapRoute(tokenIn, tokenOut, adapter, true, routeCalldata);
        console2.log("Swap route configured: tokenIn -> tokenOut via adapter");
        vm.stopBroadcast();
    }

    // --- Utility -----------------------------------------------------------------

    /**
     * @notice Precomputes the deterministic adapter address for a given deployer.
     * @dev Uses CREATE3 salt derivation - address depends only on deployer + salt, not bytecode.
     *      Call off-chain before run() to know the adapter address in advance.
     * @param deployer Address that will broadcast run().
     * @return The deterministic UniswapV3Adapter address.
     */
    function computeAdapterAddress(address deployer) public pure returns (address) {
        return _computeProxyAddress(deployer, ADAPTER_SALT);
    }
}
