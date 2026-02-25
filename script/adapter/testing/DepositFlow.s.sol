// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICatalysisCoverAdapter } from "../../../src/adapter/interfaces/ICatalysisCoverAdapter.sol";
import { IVaultV2 } from "../../../src/adapter/interfaces/Morpho/IVaultV2.sol";

/**
 * @title DepositFlow
 * @notice Tests the deposit flow for the CatalysisCoverAdapter on a live testnet.
 *         Verifies that depositing into the parent vault correctly stores the user's
 *         principal in the adapter's per-user accounting.
 *
 * @dev Flow tested:
 *      1. Approve underlying asset to the parent vault
 *      2. Call deposit() on the parent vault (which routes through the adapter)
 *      3. Verify userPrincipal[user] in the adapter increased by depositAmount
 *      4. Verify userUnderlyingShares[user] and totalPrincipal updated correctly
 *
 * Usage:
 *   forge script script/testing/DepositFlow.s.sol:DepositFlow \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - USER_PRIVATE_KEY:  Private key of the depositing user
 *   - PARENT_VAULT:      Address of the Covered Vault (Morpho V2)
 *   - ADAPTER:           Address of the CatalysisCoverAdapter
 *   - DEPOSIT_AMOUNT:    Amount of underlying asset to deposit (in smallest unit, e.g. 100000000 = 100 USDC)
 *
 * Prerequisites:
 *   - User must hold at least DEPOSIT_AMOUNT of the underlying asset
 *   - Policy must be bound (policyBoundExecuted = true) so absoluteCap > 0 and deposit can proceed
 */
contract DepositFlow is Script {
    /// @notice User address derived from private key
    address public user;

    /// @notice User's private key for signing transactions
    uint256 public userPrivateKey;

    /// @notice Covered Vault (Morpho V2) address
    address public parentVault;

    /// @notice CatalysisCoverAdapter address
    address public adapter;

    /// @notice Amount of underlying asset to deposit (in token decimals)
    uint256 public depositAmount;

    /// @notice Underlying asset address (derived from parentVault)
    address public asset;

    constructor() {
        userPrivateKey = vm.envUint("USER_PRIVATE_KEY");
        user = vm.addr(userPrivateKey);
        parentVault = vm.envAddress("PARENT_VAULT");
        adapter = vm.envAddress("ADAPTER");
        depositAmount = vm.envUint("DEPOSIT_AMOUNT");
        asset = IVaultV2(parentVault).asset();
    }

    function run() external {
        ICatalysisCoverAdapter adapterContract = ICatalysisCoverAdapter(adapter);

        console.log("=== FLOW: DEPOSIT ===");
        console.log("User:", user);
        console.log("Parent Vault:", parentVault);
        console.log("Adapter:", adapter);
        console.log("Asset:", asset);
        console.log("Deposit Amount:", depositAmount);

        // Pre-deposit snapshot
        uint256 userAssetBalanceBefore = IERC20(asset).balanceOf(user);
        uint256 userVaultSharesBefore = IVaultV2(parentVault).balanceOf(user);
        uint256 userPrincipalBefore = adapterContract.userPrincipal(user);
        uint256 userUnderlyingSharesBefore = adapterContract.userUnderlyingShares(user);
        uint256 totalPrincipalBefore = adapterContract.totalPrincipal();

        console.log("\n--- Pre-Deposit State ---");
        console.log("User asset balance:", userAssetBalanceBefore);
        console.log("User parent-vault shares:", userVaultSharesBefore);
        console.log("Adapter userPrincipal[user]:", userPrincipalBefore);
        console.log("Adapter userUnderlyingShares[user]:", userUnderlyingSharesBefore);
        console.log("Adapter totalPrincipal:", totalPrincipalBefore);
        console.log("Adapter currentValue:", adapterContract.currentValue());

        require(userAssetBalanceBefore >= depositAmount, "User has insufficient asset balance for deposit");
        require(
            adapterContract.policyBoundExecuted(),
            "Policy not yet bound on adapter - deposit will revert (absoluteCap = 0)"
        );

        // Broadcast
        vm.startBroadcast(userPrivateKey);

        // Step 1: Approve parent vault to spend the user's underlying asset
        IERC20(asset).approve(parentVault, depositAmount);
        console.log("\n[1] Approved", depositAmount, "to parent vault");

        // Step 2: Deposit into the parent vault
        //         The vault routes funds through the adapter → underlying vault
        uint256 sharesReceived = IVaultV2(parentVault).deposit(depositAmount, user);
        console.log("[2] Deposited assets, received vault shares:", sharesReceived);

        vm.stopBroadcast();

        // Verification
        _logDeposit(
            adapterContract,
            userAssetBalanceBefore,
            userVaultSharesBefore,
            userPrincipalBefore,
            userUnderlyingSharesBefore,
            totalPrincipalBefore
        );

        console.log("\n=== DEPOSIT FLOW COMPLETED ===");
    }

    function _logDeposit(
        ICatalysisCoverAdapter adapterContract,
        uint256 userAssetBalanceBefore,
        uint256 userVaultSharesBefore,
        uint256 userPrincipalBefore,
        uint256 userUnderlyingSharesBefore,
        uint256 totalPrincipalBefore
    ) internal view {
        console.log("\n--- Post-Deposit Verification ---");

        uint256 userAssetBalanceAfter = IERC20(asset).balanceOf(user);
        uint256 userVaultSharesAfter = IVaultV2(parentVault).balanceOf(user);
        uint256 userPrincipalAfter = adapterContract.userPrincipal(user);
        uint256 userUnderlyingSharesAfter = adapterContract.userUnderlyingShares(user);
        uint256 totalPrincipalAfter = adapterContract.totalPrincipal();

        console.log("User asset balance:             ", userAssetBalanceBefore, "->", userAssetBalanceAfter);
        console.log("User parent-vault shares:       ", userVaultSharesBefore, "->", userVaultSharesAfter);
        console.log("Adapter userPrincipal[user]:    ", userPrincipalBefore, "->", userPrincipalAfter);
        console.log("Adapter userUnderlyingShares:   ", userUnderlyingSharesBefore, "->", userUnderlyingSharesAfter);
        console.log("Adapter totalPrincipal:         ", totalPrincipalBefore, "->", totalPrincipalAfter);
        console.log("Adapter currentValue after:     ", adapterContract.currentValue());
    }
}
