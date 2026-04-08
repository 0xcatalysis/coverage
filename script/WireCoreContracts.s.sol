// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

interface IStakeManagerWire {
    function setCoverPoolFactory(address factory) external;
}

interface ISlashingManagerWire {
    function setClaimManager(address claimManager) external;
}

interface IRewardsManagerWire {
    function setPremiumManager(address premiumManager) external;
}

/**
 * @title WireCoreContracts
 * @notice Performs the four post-deployment cross-system wiring calls between Catalysis Core
 *         and Catalysis Coverage that neither deploy script executes.
 *
 * @dev Must be run AFTER both Core (Phase 1) and Coverage (Phase 2) are deployed.
 *      The deployer must still hold the following roles at the time this script runs:
 *        - STAKE_MANAGER_CONFIG_ROLE on StakeManager  (for setCoverPoolFactory)
 *        - DEFAULT_ADMIN_ROLE on StakeManager          (for grantRole POLICY_MANAGER_ROLE)
 *        - DEFAULT_ADMIN_ROLE on SlashingManager       (for setClaimManager)
 *        - REWARDS_MANAGER_CONFIG_ROLE on RewardsManager (for setPremiumManager — NOT DEFAULT_ADMIN_ROLE)
 *
 *      Wiring calls performed:
 *        1. StakeManager.setCoverPoolFactory(coverPoolFactory)
 *           Unblocks createCommittee() — _validateCoverPool() reverts with ZeroAddress() otherwise.
 *
 *        2. StakeManager.grantRole(POLICY_MANAGER_ROLE, policyManager)
 *           Unblocks PolicyManager.requestCoverage() → createCommittee() / addOperatorToCommittee().
 *
 *        3. SlashingManager.setClaimManager(claimManager)
 *           Atomically grants CLAIM_MANAGER_ROLE to ClaimManager, unblocks executeSlashing().
 *
 *        4. RewardsManager.setPremiumManager(premiumManager)
 *           Grants PREMIUM_MANAGER_ROLE to PremiumManager, unblocks distributeRewards().
 *
 * Usage:
 *   STAKE_MANAGER=0x... SLASHING_MANAGER=0x... REWARDS_MANAGER=0x... \
 *   POLICY_MANAGER=0x... CLAIM_MANAGER=0x... PREMIUM_MANAGER=0x... \
 *   COVER_POOL_FACTORY=0x... PRIVATE_KEY=0x... \
 *     forge script script/WireCoreContracts.s.sol:WireCoreContracts \
 *       --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
 */
contract WireCoreContracts is Script {
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");

    function run() external {
        address stakeManager = vm.envAddress("STAKE_MANAGER");
        address slashingManager = vm.envAddress("SLASHING_MANAGER");
        address rewardsManager = vm.envAddress("REWARDS_MANAGER");
        address policyManager = vm.envAddress("POLICY_MANAGER");
        address claimManager = vm.envAddress("CLAIM_MANAGER");
        address premiumManager = vm.envAddress("PREMIUM_MANAGER");
        address coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Set coverPoolFactory on StakeManager.
        //    Required role: STAKE_MANAGER_CONFIG_ROLE (held by deployer after Core deploy).
        //    Effect: _validateCoverPool() in createCommittee() no longer reverts.
        IStakeManagerWire(stakeManager).setCoverPoolFactory(coverPoolFactory);
        console.log("StakeManager.setCoverPoolFactory set to", coverPoolFactory);

        // 2. Grant POLICY_MANAGER_ROLE to PolicyManager on StakeManager.
        //    Required role: DEFAULT_ADMIN_ROLE (held by deployer after Core deploy).
        //    Effect: PolicyManager.requestCoverage() can call createCommittee() and addOperatorToCommittee().
        IAccessControl(stakeManager).grantRole(POLICY_MANAGER_ROLE, policyManager);
        console.log("StakeManager: granted POLICY_MANAGER_ROLE to", policyManager);

        // 3. Set ClaimManager on SlashingManager.
        //    Required role: DEFAULT_ADMIN_ROLE (held by deployer after Core deploy).
        //    Effect: atomically revokes old CLAIM_MANAGER_ROLE and grants it to claimManager;
        //            ClaimManager.executeSlashing() can now call SlashingManager.executeSlashing().
        ISlashingManagerWire(slashingManager).setClaimManager(claimManager);
        console.log("SlashingManager.setClaimManager set to", claimManager);

        // 4. Set PremiumManager on RewardsManager.
        //    Required role: REWARDS_MANAGER_CONFIG_ROLE (held by deployer after Core deploy).
        //    NOTE: This is NOT DEFAULT_ADMIN_ROLE — the asymmetric guard is intentional.
        //    Effect: grants PREMIUM_MANAGER_ROLE to premiumManager;
        //            PremiumManager.distributePremium() can now call RewardsManager.distributeRewards().
        IRewardsManagerWire(rewardsManager).setPremiumManager(premiumManager);
        console.log("RewardsManager.setPremiumManager set to", premiumManager);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Cross-System Wiring Complete ===");
        console.log("StakeManager:     ", stakeManager);
        console.log("  coverPoolFactory:", coverPoolFactory);
        console.log("  POLICY_MANAGER_ROLE granted to:", policyManager);
        console.log("SlashingManager:  ", slashingManager);
        console.log("  claimManager:   ", claimManager);
        console.log("RewardsManager:   ", rewardsManager);
        console.log("  premiumManager: ", premiumManager);
    }
}
