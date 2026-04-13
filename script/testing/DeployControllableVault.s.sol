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
 *      Ownership transfer (two-step):
 *        If VAULT_ADMIN differs from DEPLOYER_ADDRESS, this script calls transferAdmin(VAULT_ADMIN)
 *        at the end of deployment. The nominated admin must then call acceptAdmin() to take effect.
 *        Until acceptAdmin() is called, the deployer retains the admin role.
 *
 * Usage:
 *   forge script script/testing/DeployControllableVault.s.sol:DeployControllableVault \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS:  Public address of the keystore signer (used with --keystore flag)
 *   - ASSET_ADDRESS:     ERC-20 underlying token (e.g. WETH); must equal PAYOUT_TOKEN
 *
 * Optional Environment Variables:
 *   - VAULT_ADMIN:  Address to receive vault admin role (can call simulateLoss).
 *                   Defaults to DEPLOYER_ADDRESS. Set to a multisig for production deployments.
 *                   The nominated address must call acceptAdmin() to complete the transfer.
 */
contract DeployControllableVault is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address asset = vm.envAddress("ASSET_ADDRESS");
        address vaultAdmin = vm.envOr("VAULT_ADMIN", deployer);

        require(asset != address(0), "ASSET_ADDRESS must not be zero address");
        require(vaultAdmin != address(0), "VAULT_ADMIN must not be zero address");

        console.log("=== DEPLOY CONTROLLABLE VAULT ===");
        console.log("Deployer:   ", deployer);
        console.log("Vault admin:", vaultAdmin);
        console.log("Asset:      ", asset);

        vm.startBroadcast(deployer);
        ControllableVault vault = new ControllableVault(asset);

        if (vaultAdmin != deployer) {
            vault.transferAdmin(vaultAdmin);
        }

        vm.stopBroadcast();

        console.log("\n--- Verification ---");
        require(vault.asset() == asset, "Asset mismatch");

        if (vaultAdmin == deployer) {
            require(vault.admin() == deployer, "Admin not set to deployer");
            console.log("Admin (active):", vault.admin());
        } else {
            require(vault.admin() == deployer, "Deployer should still be active admin until acceptAdmin()");
            require(vault.pendingAdmin() == vaultAdmin, "Pending admin not set correctly");
            console.log("Admin (active, pending transfer):", vault.admin());
            console.log("Pending admin (must call acceptAdmin):", vault.pendingAdmin());
            console.log("[ACTION REQUIRED] Call acceptAdmin() from:", vaultAdmin);
        }

        console.log("\nControllableVault deployed at:", address(vault));
        console.log("Asset:                        ", vault.asset());
        console.log("\nSet this env var for downstream scripts:");
        console.log("MORPHO_VAULT=", address(vault));
        console.log("\n=== DONE ===");
    }
}
