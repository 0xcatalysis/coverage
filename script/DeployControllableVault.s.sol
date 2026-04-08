// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ControllableVault} from "../test/defi/mocks/ControllableVault.sol";

/**
 * @title DeployControllableVault
 * @notice Deploys a ControllableVault to act as a mock Morpho vault for testing CoveredVaultWrapper.
 *
 * @dev ControllableVault is a plain ERC-4626 implementation backed by a real ERC-20 balance.
 *      It is NOT a proxy — admin defaults to the deployer (msg.sender at construction time).
 *
 *      The resulting address should be passed as MORPHO_VAULT when deploying CoveredVaultWrapper.
 *
 *      Admin controls:
 *        - simulateLoss(amount)  : drains assets to simulate a hack (onlyAdmin)
 *        - simulateProfit(amount): injects assets to simulate yield (public, requires approval)
 *        - transferAdmin / acceptAdmin: two-step admin rotation
 *
 * Usage:
 *   ASSET_ADDRESS=0x... PRIVATE_KEY=0x... \
 *     forge script script/testing/DeployControllableVault.s.sol:DeployControllableVault \
 *       --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY:    Deployer private key. Deployer becomes the vault admin.
 *   - ASSET_ADDRESS:  Underlying ERC-20 token address (e.g. USDC or WETH on Sepolia).
 *
 * Sepolia token addresses:
 *   USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
 *   WETH: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
 */
contract DeployControllableVault is Script {
    function run() external returns (address vault) {
        address asset = vm.envAddress("ASSET_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        require(asset != address(0), "ASSET_ADDRESS required");

        vm.startBroadcast(deployerPrivateKey);
        vault = address(new ControllableVault(asset));
        vm.stopBroadcast();

        console.log("ControllableVault deployed at:", vault);
        console.log("  asset:           ", asset);
        console.log("  admin (deployer):", vm.addr(deployerPrivateKey));
        console.log("");
        console.log("Set MORPHO_VAULT=", vault, "before running DeployCoveredVaultWrapper.");
    }
}
