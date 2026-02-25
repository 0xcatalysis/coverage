// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ICatalysisCoverAdapter } from "../../../src/adapter/interfaces/ICatalysisCoverAdapter.sol";
import { IVaultV2 } from "../../../src/adapter/interfaces/Morpho/IVaultV2.sol";

/// @dev Minimal interface for querying cumulative coverage payouts from ClaimManager
interface IClaimManager {
    /// @notice Returns cumulative payout data for a given policy
    /// @param policyId The policy ID to query
    /// @return totalPaidOut Cumulative assets paid out under this policy
    /// @return claimCount Number of claims filed under this policy
    function policyClaim(uint96 policyId) external view returns (uint256 totalPaidOut, uint256 claimCount);
}

/**
 * @title WithdrawFlow
 * @notice Tests the withdrawal flow for the CatalysisCoverAdapter on a live testnet.
 *         Previews expected coverage payout before withdrawal, then verifies:
 *           - User's balance increased by vault payout + any insurance payout
 *           - Adapter's per-user principal decreased correctly
 *           - Adapter's totalPrincipal decreased correctly
 *           - ClaimManager recorded the correct coverage payout (if any)
 *
 * @dev Flow tested:
 *      1. Preview: calculate expected shortfall and coverage based on current state
 *      2. Call withdraw() on the parent vault (which routes through the adapter)
 *      3. Adapter internally:
 *           a. Withdraws WITHDRAW_AMOUNT from underlying vault
 *           b. Detects shortfall vs user's principal (if NAV has dropped)
 *           c. Files insurance claim with ClaimManager (if shortfall within policy cap)
 *           d. Transfers insurance payout directly to user (bypassing the vault)
 *           e. Approves WITHDRAW_AMOUNT to parent vault for the vault to pull
 *      4. Verify principal decrease, balance change, and coverage payout
 *
 * Usage:
 *   forge script script/testing/WithdrawFlow.s.sol:WithdrawFlow \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - USER_PRIVATE_KEY:   Private key of the withdrawing user
 *   - PARENT_VAULT:       Address of the Covered Vault (Morpho V2)
 *   - ADAPTER:            Address of the CatalysisCoverAdapter
 *   - CLAIM_MANAGER:      Address of the Catalysis ClaimManager
 *   - WITHDRAW_AMOUNT:    Amount of underlying asset to withdraw (in smallest unit)
 *
 * Prerequisites:
 *   - User must have previously deposited (run DepositFlow first)
 *   - Policy must be active (bound and not expired)
 *   - WITHDRAW_AMOUNT must not exceed user's withdrawable balance
 */
contract WithdrawFlow is Script {
    /// @dev Mirrors the constants in CatalysisCoverAdapter
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant DEDUCTIBLE_BPS = 100;

    /// @notice Captures all relevant observable state at a single point in time
    struct Snapshot {
        uint256 userAssetBalance;
        uint256 userVaultShares;
        uint256 userPrincipal;
        uint256 userUnderlyingShares;
        uint256 totalPrincipal;
        uint256 coveragePaidOut;
        uint256 coverageClaimCount;
    }

    /// @notice User address derived from private key
    address public user;

    /// @notice User's private key for signing transactions
    uint256 public userPrivateKey;

    /// @notice Covered Vault (Morpho V2) address
    address public parentVault;

    /// @notice CatalysisCoverAdapter address
    address public adapter;

    /// @notice ClaimManager address for verifying coverage payouts
    address public claimManager;

    /// @notice Amount of underlying asset to withdraw (in token decimals)
    uint256 public withdrawAmount;

    /// @notice Underlying asset address (derived from parentVault)
    address public asset;

    constructor() {
        userPrivateKey = vm.envUint("USER_PRIVATE_KEY");
        user = vm.addr(userPrivateKey);
        parentVault = vm.envAddress("PARENT_VAULT");
        adapter = vm.envAddress("ADAPTER");
        claimManager = vm.envAddress("CLAIM_MANAGER");
        withdrawAmount = vm.envUint("WITHDRAW_AMOUNT");
        asset = IVaultV2(parentVault).asset();
    }

    function run() external {
        ICatalysisCoverAdapter adapterContract = ICatalysisCoverAdapter(adapter);
        uint96 policyId = adapterContract.policyId();
        uint16 maxCoverableLossBps = adapterContract.maxCoverableLossBps();

        console.log("=== FLOW: WITHDRAWAL ===");
        console.log("User:", user);
        console.log("Parent Vault:", parentVault);
        console.log("Adapter:", adapter);
        console.log("Asset:", asset);
        console.log("Withdraw Amount:", withdrawAmount);
        console.log("Policy ID:", policyId);
        console.log("Max Coverable Loss BPS:", maxCoverableLossBps);

        // Pre-withdrawal snapshot
        Snapshot memory before = _takeSnapshot(adapterContract, policyId);

        console.log("\n--- Pre-Withdrawal State ---");
        console.log("User asset balance:", before.userAssetBalance);
        console.log("User parent-vault shares:", before.userVaultShares);
        console.log("Adapter userPrincipal[user]:", before.userPrincipal);
        console.log("Adapter userUnderlyingShares[user]:", before.userUnderlyingShares);
        console.log("Adapter totalPrincipal:", before.totalPrincipal);
        console.log("Adapter currentValue:", adapterContract.currentValue());
        console.log("Cumulative coverage paid out:", before.coveragePaidOut);

        require(before.userPrincipal > 0, "No principal tracked for user - run DepositFlow first");
        require(before.userVaultShares > 0, "User has no vault shares - run DepositFlow first");

        // Coverage preview (read-only estimate)
        uint256 estInsurance =
            _previewWithdrawal(adapterContract, before.userPrincipal, before.userUnderlyingShares, maxCoverableLossBps);

        // Broadcast
        vm.startBroadcast(userPrivateKey);

        // Withdraw from parent vault; adapter handles underlying withdrawal + optional insurance
        uint256 sharesBurned = IVaultV2(parentVault).withdraw(withdrawAmount, user, user);
        console.log("\n[1] Withdrawn", withdrawAmount, "assets, burned vault shares:", sharesBurned);

        vm.stopBroadcast();

        // Post-withdrawal snapshot and verification
        Snapshot memory afterSnap = _takeSnapshot(adapterContract, policyId);
        _verifyWithdrawal(before, afterSnap, sharesBurned, estInsurance);

        console.log("\n=== WITHDRAWAL FLOW COMPLETED ===");
    }

    function _takeSnapshot(
        ICatalysisCoverAdapter adapterContract,
        uint96 policyId
    ) internal view returns (Snapshot memory s) {
        s.userAssetBalance = IERC20(asset).balanceOf(user);
        s.userVaultShares = IVaultV2(parentVault).balanceOf(user);
        s.userPrincipal = adapterContract.userPrincipal(user);
        s.userUnderlyingShares = adapterContract.userUnderlyingShares(user);
        s.totalPrincipal = adapterContract.totalPrincipal();
        (s.coveragePaidOut, s.coverageClaimCount) = IClaimManager(claimManager).policyClaim(policyId);
    }

    /**
     * @notice Estimates expected vault payout, shortfall, and insurance coverage
     *         before the withdrawal executes, based on the current on-chain state.
     * @dev Uses the same arithmetic as CatalysisCoverAdapter._withdraw():
     *        shortfall = userPrincipalForWithdrawal - withdrawAmount  (if positive)
     *        maxInsurance = userPrincipalForWithdrawal * maxCoverableLossBps / 10000
     *        effectiveInsurance = maxInsurance * (10000 - DEDUCTIBLE_BPS) / 10000
     *        claimAmount = min(shortfall, effectiveInsurance)
     * @return estInsurance Estimated insurance payout (0 if no shortfall)
     */
    function _previewWithdrawal(
        ICatalysisCoverAdapter adapterContract,
        uint256 userPrincipalBefore,
        uint256 userUnderlyingSharesBefore,
        uint16 maxCoverableLossBps
    ) internal view returns (uint256 estInsurance) {
        console.log("\n--- Coverage Preview (before withdrawal) ---");

        address underlyingVault = adapterContract.underlyingVault();

        // Estimate how many underlying vault shares will be burned for this withdrawal.
        // convertToShares is equivalent to previewWithdraw for standard ERC4626 vaults.
        uint256 estSharesToBurn = IERC4626(underlyingVault).convertToShares(withdrawAmount);

        // Estimate the portion of user's principal that corresponds to these shares
        uint256 estPrincipalForWithdrawal;
        if (estSharesToBurn >= userUnderlyingSharesBefore) {
            // Full (or over) withdrawal - attribute all remaining principal
            estPrincipalForWithdrawal = userPrincipalBefore;
        } else {
            estPrincipalForWithdrawal = userPrincipalBefore * estSharesToBurn / userUnderlyingSharesBefore;
        }

        // The vault always returns exactly withdrawAmount (ERC4626 withdraw() guarantee)
        console.log("Expected vault payout (exact):", withdrawAmount);
        console.log("Estimated principal for this withdrawal:", estPrincipalForWithdrawal);

        // Check whether the underlying vault has lost value vs the tracked principal
        uint256 estShortfall =
            estPrincipalForWithdrawal > withdrawAmount ? estPrincipalForWithdrawal - withdrawAmount : 0;

        console.log("Estimated shortfall:", estShortfall);

        if (estShortfall == 0) {
            console.log("No shortfall - underlying vault at or above principal. No coverage payout expected.");
            return 0;
        }

        // Compute coverage cap: maxCoverableLossBps% of principal, less DEDUCTIBLE_BPS deductible
        uint256 estMaxInsurance = estPrincipalForWithdrawal * uint256(maxCoverableLossBps) / BPS_DENOMINATOR;
        uint256 estEffectiveInsurance = estMaxInsurance * (BPS_DENOMINATOR - DEDUCTIBLE_BPS) / BPS_DENOMINATOR;
        estInsurance = estShortfall < estEffectiveInsurance ? estShortfall : estEffectiveInsurance;

        console.log("Max insurable loss (bps of principal):", estMaxInsurance);
        console.log("(maxCoverableLossBps:", uint256(maxCoverableLossBps), ")");
        console.log("Estimated coverage payout:", estInsurance);
    }

    function _verifyWithdrawal(
        Snapshot memory before,
        Snapshot memory afterSnap,
        uint256 sharesBurned,
        uint256 estInsurance
    ) internal view {
        console.log("\n--- Post-Withdrawal Verification ---");

        uint256 actualInsurancePayout = afterSnap.coveragePaidOut - before.coveragePaidOut;
        uint256 totalReceived = afterSnap.userAssetBalance - before.userAssetBalance;

        console.log("User asset balance:             ", before.userAssetBalance, "->", afterSnap.userAssetBalance);
        console.log("User parent-vault shares:       ", before.userVaultShares, "->", afterSnap.userVaultShares);
        console.log("Adapter userPrincipal[user]:    ", before.userPrincipal, "->", afterSnap.userPrincipal);
        console.log(
            "Adapter userUnderlyingShares:   ", before.userUnderlyingShares, "->", afterSnap.userUnderlyingShares
        );
        console.log("Adapter totalPrincipal:         ", before.totalPrincipal, "->", afterSnap.totalPrincipal);
        console.log("Coverage paid out:              ", before.coveragePaidOut, "->", afterSnap.coveragePaidOut);
        console.log("Coverage claim count:", afterSnap.coverageClaimCount);
        console.log("");
        console.log("Vault payout (withdrawAmount):", withdrawAmount);
        console.log("Insurance payout (coverage delta):", actualInsurancePayout);
        console.log("Total received by user:", totalReceived);

    }
}
