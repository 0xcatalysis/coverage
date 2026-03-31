// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPremiumCollector} from "../../src/interfaces/IPremiumCollector.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

/**
 * @title DistributePremium
 * @notice Distributes premiums from the PremiumCollector through the PremiumManager to restakers via SSPRouter.
 * @dev Corresponds to Document Flows 6-7:
 *      Flow 6 – Premiums Accrue:
 *        6a. PremiumCollector is registered as the managementFeesRecipient in the covered vault
 *        6b. PremiumCollector collects premiums (vault shares), converts to underlying, sends to PremiumManager
 *      Flow 7 – Premiums Are Distributed:
 *        7a. PremiumManager accounts for platform/pool fees and retains the restaker split
 *        7b. PremiumManager calls RewardsManager.distributeRewards; RewardsManager forwards to
 *            SSPRouter which pulls the restaker share directly from PremiumManager via the
 *            allowance pre-set by admin (PremiumManager.approveSpender(token, sspRouter, ...))
 *
 *      For E2E testing on Sepolia, vault shares may not yet exist in PremiumCollector because no
 *      real management fees have accrued. Set BOOTSTRAP_PREMIUM_AMOUNT to a non-zero value to
 *      trigger a bootstrap phase that deposits underlying tokens into the vault and transfers the
 *      resulting shares directly to PremiumCollector, simulating premium accrual.
 *
 * Usage:
 *   forge script script/testing/DistributePremium.s.sol:DistributePremium \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Private key of the caller (admin for registration, anyone for distribution)
 *   - PREMIUM_COLLECTOR: PremiumCollector proxy address
 *   - PREMIUM_MANAGER: PremiumManager proxy address
 *   - COVERED_VAULT: ERC-4626 vault address that accrues premiums
 *   - COVER_POOL: CoverPool address associated with the vault
 *   - POLICY_ID: Policy ID (1:1 with committeeId)
 *
 * Optional Environment Variables:
 *   - BOOTSTRAP_PREMIUM_AMOUNT: If > 0, deposits this amount of underlying into the vault and
 *                               transfers the minted shares to PremiumCollector. Used for E2E
 *                               testing when no real premium has accrued yet. Default: 0 (skip).
 *
 * Prerequisites:
 *   - Policy must be bound (Flow 5 completed)
 *   - PremiumCollector must have PREMIUM_COLLECTOR_ROLE on PremiumManager
 *   - PremiumManager must have approved SSPRouter for the premium token (via approveSpender)
 *   - Vault must support ERC-4626 deposits (required when BOOTSTRAP_PREMIUM_AMOUNT > 0)
 */
contract DistributePremium is Script {
    using SafeERC20 for IERC20;

    /// @notice Deployer/caller address
    address public deployer;

    /// @notice Deployer's private key
    uint256 public deployerPrivateKey;

    /// @notice PremiumCollector proxy address
    address public premiumCollector;

    /// @notice PremiumManager proxy address
    address public premiumManager;

    /// @notice Covered vault (ERC-4626) address
    address public coveredVault;

    /// @notice CoverPool address
    address public coverPool;

    /// @notice Policy ID
    uint96 public policyId;

    /// @notice Optional: deposit this amount of underlying into the vault and transfer
    ///         shares to PremiumCollector to simulate premium accrual for E2E testing.
    ///         Set to 0 (default) to skip.
    uint256 public bootstrapPremiumAmount;

    /// @notice Contract instances
    IPremiumCollector public collectorContract;
    IPremiumManager public managerContract;

    /// @notice Emitted when premiums are distributed
    event PremiumsDistributed(
        address indexed vault, uint96 indexed policyId, uint256 sharesRedeemed, uint256 assetsDistributed
    );

    /// @notice Emitted when E2E bootstrap shares are seeded into PremiumCollector
    event PremiumBootstrapped(address indexed vault, address indexed underlying, uint256 amount, uint256 shares);

    constructor() {
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        premiumCollector = vm.envAddress("PREMIUM_COLLECTOR");
        premiumManager = vm.envAddress("PREMIUM_MANAGER");
        coveredVault = vm.envAddress("COVERED_VAULT");
        coverPool = vm.envAddress("COVER_POOL");
        policyId = uint96(vm.envUint("POLICY_ID"));
        bootstrapPremiumAmount = vm.envOr("BOOTSTRAP_PREMIUM_AMOUNT", uint256(0));

        collectorContract = IPremiumCollector(premiumCollector);
        managerContract = IPremiumManager(premiumManager);
    }

    function run() external {
        console.log("=== FLOWS 6-7: PREMIUM COLLECTION & DISTRIBUTION ===");
        console.log("Caller:", deployer);
        console.log("PremiumCollector:", premiumCollector);
        console.log("PremiumManager:", premiumManager);
        console.log("Covered Vault:", coveredVault);
        console.log("CoverPool:", coverPool);
        console.log("Policy ID:", policyId);
        if (bootstrapPremiumAmount > 0) {
            console.log("Bootstrap premium amount:", bootstrapPremiumAmount);
        }

        _registerVaultIfNeeded();
        if (bootstrapPremiumAmount > 0) _bootstrapPremiumShares();
        _checkAccruedShares();
        _checkFeeConfiguration();
        _distributePremiums();

        console.log("\n=== PREMIUM DISTRIBUTION COMPLETED ===");
    }

    function _registerVaultIfNeeded() internal {
        console.log("\n--- Phase 1: Vault Registration ---");

        IPremiumCollector.VaultConfig memory config = collectorContract.getVaultConfig(coveredVault);

        if (config.registered) {
            console.log("Vault already registered");
            console.log("  Pool:", config.pool);
            console.log("  Policy ID:", config.policyId);
            console.log("  Underlying:", config.underlying);
            return;
        }

        console.log("Registering vault in PremiumCollector...");

        vm.startBroadcast(deployerPrivateKey);
        collectorContract.registerVault(coveredVault, coverPool, policyId);
        vm.stopBroadcast();

        config = collectorContract.getVaultConfig(coveredVault);
        console.log("Vault registered:");
        console.log("  Pool:", config.pool);
        console.log("  Policy ID:", config.policyId);
        console.log("  Underlying:", config.underlying);
        require(config.registered, "Vault registration failed");
        console.log("[OK] Vault registered");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //  E2E Bootstrap: seed vault shares into PremiumCollector
    //  Only runs when BOOTSTRAP_PREMIUM_AMOUNT > 0.
    //
    //  In production, vault management fees accrue automatically and are pushed to
    //  PremiumCollector by the vault's fee distribution mechanism. For Sepolia E2E
    //  testing we simulate this by depositing directly into the vault and transferring
    //  the minted shares to PremiumCollector.
    // ─────────────────────────────────────────────────────────────────────────────

    function _bootstrapPremiumShares() internal {
        console.log("\n--- Bootstrap: Seeding Premium Shares into PremiumCollector ---");

        IERC4626 vault = IERC4626(coveredVault);
        address underlying = vault.asset();

        uint256 callerBalance = IERC20(underlying).balanceOf(deployer);
        console.log("Caller underlying balance:", callerBalance);
        require(callerBalance >= bootstrapPremiumAmount, "Insufficient underlying balance for bootstrap");

        console.log("Depositing amount:", bootstrapPremiumAmount);
        console.log("  Underlying token:", underlying);
        console.log("  Into vault:", coveredVault);

        vm.startBroadcast(deployerPrivateKey);
        IERC20(underlying).approve(coveredVault, bootstrapPremiumAmount);
        // Deposit with premiumCollector as receiver so shares are minted directly to it.
        // Wrapper shares are soulbound — transferring them after minting always reverts.
        uint256 shares = vault.deposit(bootstrapPremiumAmount, premiumCollector);
        vm.stopBroadcast();

        console.log("[OK] Deposited", shares, "shares directly to PremiumCollector");
        emit PremiumBootstrapped(coveredVault, underlying, bootstrapPremiumAmount, shares);
    }

    function _checkAccruedShares() internal view {
        console.log("\n--- Phase 2: Accrued Shares ---");

        uint256 shares = collectorContract.getAccruedShares(coveredVault);
        console.log("Accrued shares:", shares);

        if (shares == 0) {
            console.log("[WARNING] No shares accrued yet. Transfer vault shares to PremiumCollector first.");
        }

        uint256 previewAssets = IERC4626(coveredVault).previewRedeem(shares);
        console.log("Preview redeem assets:", previewAssets);
    }

    function _checkFeeConfiguration() internal view {
        console.log("\n--- Phase 3: Fee Configuration ---");

        uint16 platformFeeBps = managerContract.platformFeeBps();
        console.log("Platform Fee BPS:", platformFeeBps);

        uint16 poolFeeBps = ICoverPool(coverPool).poolFeeBps();
        console.log("Pool Fee BPS:", poolFeeBps);

        address feeRecipient = ICoverPool(coverPool).feeRecipient();
        console.log("Pool Fee Recipient:", feeRecipient);

        address treasury = managerContract.platformTreasury();
        console.log("Platform Treasury:", treasury);

        // Calculate example splits
        uint256 examplePremium = 1 ether;
        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            managerContract.getFeeSplits(examplePremium, platformFeeBps, poolFeeBps);

        console.log("Example split for 1 token premium:");
        console.log("  Platform:", platformSplit);
        console.log("  Pool Curator:", poolSplit);
        console.log("  Restakers:", restakerSplit);
    }

    function _distributePremiums() internal {
        console.log("\n--- Phase 4: Premium Distribution ---");

        uint256 shares = collectorContract.getAccruedShares(coveredVault);
        if (shares == 0) {
            console.log("[SKIP] No shares to distribute");
            return;
        }

        if (!_isVaultDistributable()) {
            console.log("[SKIP] Vault not yet distributable (interval not elapsed)");
            return;
        }

        address underlying = collectorContract.getVaultConfig(coveredVault).underlying;
        address onChainTreasury = managerContract.platformTreasury();
        address poolFeeRecipient = ICoverPool(coverPool).feeRecipient();

        console.log("Distributing premiums for vault:", coveredVault);
        console.log("Shares to redeem:", shares);

        (uint256 restakerSplit, uint256 treasuryReceived, uint256 poolFeeRecipientReceived) =
            _executeDistribution(underlying, onChainTreasury, poolFeeRecipient);

        console.log("Restaker split (pulled by SSPRouter):", restakerSplit);
        console.log("Platform Treasury received:", treasuryReceived);
        console.log("Pool Fee Recipient received:", poolFeeRecipientReceived);

        uint256 sharesAfter = collectorContract.getAccruedShares(coveredVault);
        console.log("Remaining shares:", sharesAfter);
        require(sharesAfter == 0, "Shares not fully redeemed");

        console.log("[SUCCESS] Premiums distributed");
        emit PremiumsDistributed(
            coveredVault, policyId, shares, restakerSplit + treasuryReceived + poolFeeRecipientReceived
        );
    }

    function _isVaultDistributable() internal view returns (bool) {
        address[] memory distributableVaults = collectorContract.getDistributableVaults();
        for (uint256 i = 0; i < distributableVaults.length; i++) {
            if (distributableVaults[i] == coveredVault) {
                return true;
            }
        }
        return false;
    }

    function _executeDistribution(
        address underlying,
        address onChainTreasury,
        address poolFeeRecipient
    )
        internal
        returns (uint256 restakerSplit, uint256 treasuryReceived, uint256 poolFeeRecipientReceived)
    {
        uint256 treasuryBalanceBefore = IERC20(underlying).balanceOf(onChainTreasury);
        uint256 poolFeeRecipientBalanceBefore = IERC20(underlying).balanceOf(poolFeeRecipient);

        uint256 shares = collectorContract.getAccruedShares(coveredVault);
        uint256 totalAssetsPreview = IERC4626(coveredVault).previewRedeem(shares);

        address[] memory vaultsToDistribute = new address[](1);
        vaultsToDistribute[0] = coveredVault;

        vm.startBroadcast(deployerPrivateKey);
        collectorContract.distributeBatch(vaultsToDistribute);
        vm.stopBroadcast();

        treasuryReceived = IERC20(underlying).balanceOf(onChainTreasury) - treasuryBalanceBefore;
        poolFeeRecipientReceived = IERC20(underlying).balanceOf(poolFeeRecipient) - poolFeeRecipientBalanceBefore;

        restakerSplit = totalAssetsPreview > treasuryReceived + poolFeeRecipientReceived
            ? totalAssetsPreview - treasuryReceived - poolFeeRecipientReceived
            : 0;
    }
}
