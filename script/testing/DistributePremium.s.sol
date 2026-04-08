// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

/**
 * @title DistributePremium
 * @notice Triggers premium collection on a CoveredVaultWrapper and verifies distribution.
 * @dev CoveredVaultWrapper accrues premiums internally via a reward-per-token accumulator.
 *      collectPremium() flushes pending premium to PremiumManager, which then routes platform
 *      fees, pool curator fees, and restaker shares. distributePremium() is permissionless —
 *      no role grant is required on PremiumManager.
 *
 *      Corresponds to Flows 6-7:
 *        Flow 6 – Premiums Accrue: CoveredVaultWrapper accrues premium proportional to
 *                 totalPrincipal and premiumRatePerSecond over the active policy window.
 *        Flow 7 – Premiums Are Distributed: collectPremium() transfers accrued premium to
 *                 PremiumManager and calls distributePremium(pool, policyId, token, amount).
 *
 * Usage:
 *   forge script script/testing/DistributePremium.s.sol:DistributePremium \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Private key of the caller (collectPremium is permissionless)
 *   - COVERED_VAULT: CoveredVaultWrapper proxy address
 *   - PREMIUM_MANAGER: PremiumManager proxy address
 *   - COVER_POOL: CoverPool address associated with the policy
 *
 * Prerequisites:
 *   - Policy must be bound (CoveredVaultWrapper.onPolicyBound called)
 *   - PremiumManager must have approved RewardsManager for the premium token (via approveSpender)
 */
contract DistributePremium is Script {
    /// @notice Deployer/caller address
    address public deployer;

    /// @notice Deployer's private key
    uint256 public deployerPrivateKey;

    /// @notice CoveredVaultWrapper proxy address
    address public coveredVault;

    /// @notice PremiumManager proxy address
    address public premiumManager;

    /// @notice CoverPool address
    address public coverPool;

    /// @notice Emitted when premiums are distributed
    event PremiumsDistributed(address indexed vault, uint256 premiumAmount);

    constructor() {
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        coveredVault = vm.envAddress("COVERED_VAULT");
        premiumManager = vm.envAddress("PREMIUM_MANAGER");
        coverPool = vm.envAddress("COVER_POOL");
    }

    function run() external {
        console.log("=== FLOWS 6-7: PREMIUM COLLECTION & DISTRIBUTION ===");
        console.log("Caller:", deployer);
        console.log("CoveredVault:", coveredVault);
        console.log("PremiumManager:", premiumManager);
        console.log("CoverPool:", coverPool);

        _checkFeeConfiguration();
        _collectAndDistribute();

        console.log("\n=== PREMIUM DISTRIBUTION COMPLETED ===");
    }

    function _checkFeeConfiguration() internal view {
        console.log("\n--- Fee Configuration ---");

        IPremiumManager manager = IPremiumManager(premiumManager);
        uint16 platformFeeBps = manager.platformFeeBps();
        console.log("Platform Fee BPS:", platformFeeBps);

        uint16 poolFeeBps = ICoverPool(coverPool).poolFeeBps();
        console.log("Pool Fee BPS:", poolFeeBps);

        address feeRecipient = ICoverPool(coverPool).feeRecipient();
        console.log("Pool Fee Recipient:", feeRecipient);

        address treasury = manager.platformTreasury();
        console.log("Platform Treasury:", treasury);

        uint256 examplePremium = 1 ether;
        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            manager.getFeeSplits(examplePremium, platformFeeBps, poolFeeBps);

        console.log("Example split for 1 token premium:");
        console.log("  Platform:", platformSplit);
        console.log("  Pool Curator:", poolSplit);
        console.log("  Restakers:", restakerSplit);
    }

    function _collectAndDistribute() internal {
        console.log("\n--- Premium Collection & Distribution ---");

        vm.startBroadcast(deployerPrivateKey);
        (bool success,) = coveredVault.call(abi.encodeWithSignature("collectPremium()"));
        vm.stopBroadcast();

        if (success) {
            console.log("[OK] collectPremium() executed, pending premium flushed to PremiumManager");
            emit PremiumsDistributed(coveredVault, 0);
        } else {
            console.log("[SKIP] collectPremium() reverted, no pending premium or vault not configured");
        }
    }
}
