// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ControllableVault} from "../../test/defi/mocks/ControllableVault.sol";

/**
 * @title DeployControllableVault
 * @notice Deploys a ControllableVault — a minimal ERC-4626 vault with loss/profit simulation
 *         controls — for use as the underlying vault in a CoveredVaultWrapper E2E test flow.
 *
 * @dev ControllableVault is a testing primitive that enables the full CoveredVaultWrapper
 *      insurance claim path. The CoveredVaultWrapper implements ISpec and evaluates claims
 *      by comparing a depositor's current redemption value against their recorded entry value.
 *      A loss is only detectable if the underlying vault's share price actually drops — which
 *      `simulateLoss()` achieves by draining real assets from the vault.
 *
 *      Deployment wiring (after this script):
 *        1. Deploy CoveredVaultWrapper on top of this vault (DeployCoveredVaultWrapper.s.sol)
 *        2. Register CoveredVaultWrapper as the ISpec in SpecRegistry (ApproveSpec.s.sol)
 *        3. Bind a policy with CoveredVaultWrapper as BIND_POLICY_HOOK (BindPolicy.s.sol)
 *        4. Simulate a loss: call vault.simulateLoss(amount) as admin to deflate share price
 *        5. File claim (FileClaim.s.sol) — CoveredVaultWrapper.evaluate() detects the shortfall
 *
 *      The deployer becomes the vault admin (the only address that can call simulateLoss).
 *      To rotate admin, call transferAdmin(newAdmin) then acceptAdmin() from the new admin.
 *
 * Usage:
 *   forge script script/testing/DeployControllableVault.s.sol:DeployControllableVault \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY:    Deployer key; becomes the vault admin (can call simulateLoss)
 *   - ASSET_ADDRESS:  ERC-20 underlying token (e.g. WETH); must equal PAYOUT_TOKEN
 */
contract DeployControllableVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address asset = vm.envAddress("ASSET_ADDRESS");

        require(asset != address(0), "ASSET_ADDRESS must not be zero address");

        console.log("=== DEPLOY CONTROLLABLE VAULT ===");
        console.log("Deployer / admin:", deployer);
        console.log("Asset:           ", asset);

        vm.startBroadcast(deployerKey);
        ControllableVault vault = new ControllableVault(asset);
        vm.stopBroadcast();

        console.log("\n--- Verification ---");
        require(vault.asset() == asset, "Asset mismatch");
        require(vault.admin() == deployer, "Admin not set to deployer");

        console.log("ControllableVault deployed at:", address(vault));
        console.log("Asset:                        ", vault.asset());
        console.log("Admin:                        ", vault.admin());
        console.log("\nSet this env var for downstream scripts:");
        console.log("MORPHO_VAULT=", address(vault));
        console.log("\n=== DONE ===");
    }
}
