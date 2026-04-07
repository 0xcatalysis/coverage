// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal interfaces for Core contracts — avoids adding a `../core` remapping.
interface IStakeManagerWire {
    function setCoverPoolFactory(address _coverPoolFactory) external;
    function grantRole(bytes32 role, address account) external;
    function coverPoolFactory() external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ISlashingManagerWire {
    function setClaimManager(address _claimManager) external;
    function claimManager() external view returns (address);
}

interface IRewardsManagerWire {
    function setPremiumManager(address _premiumManager) external;
    function premiumManager() external view returns (address);
}

interface IPremiumManagerWire {
    function approveSpender(address token, address spender, uint256 amount) external;
}

/**
 * @title WireCoreContracts
 * @notice Performs all cross-system wiring between Catalysis Core and Coverage contracts.
 * @dev Must be run after both Core and Coverage contracts are deployed.
 *      Executes five calls that bridge the two systems:
 *
 *      1. StakeManager.setCoverPoolFactory    — unblocks createCommittee() during requestCoverage()
 *      2. StakeManager.grantRole(POLICY_MANAGER_ROLE, policyManager) — unblocks requestCoverage()
 *      3. SlashingManager.setClaimManager     — grants CLAIM_MANAGER_ROLE, unblocks executeSlashing()
 *      4. RewardsManager.setPremiumManager    — grants PREMIUM_MANAGER_ROLE, unblocks distributeRewards()
 *      5. PremiumManager.approveSpender       — allows SSPRouter to pull tokens from PremiumManager
 *                                               for reward distribution; required for collectPremium()
 *                                               to route restaker share correctly end-to-end
 *
 *      Role requirements (all held by the deployer after Core and Coverage deploys):
 *        - STAKE_MANAGER_CONFIG_ROLE on StakeManager
 *        - DEFAULT_ADMIN_ROLE on StakeManager
 *        - DEFAULT_ADMIN_ROLE on SlashingManager
 *        - REWARDS_MANAGER_CONFIG_ROLE on RewardsManager
 *        - DEFAULT_ADMIN_ROLE on PremiumManager / Coverage
 *
 * Usage:
 *   forge script script/WireCoreContracts.s.sol:WireCoreContracts \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   Core (from DeploySepolia/DeployEthereum outputs):
 *   - STAKE_MANAGER: StakeManager proxy address
 *   - SLASHING_MANAGER: SlashingManager proxy address
 *   - REWARDS_MANAGER: RewardsManager proxy address
 *   - SSP_ROUTER: SSPRouter proxy address
 *
 *   Coverage (from script/DeploySepolia.s.sol outputs):
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - CLAIM_MANAGER: ClaimManager proxy address
 *   - PREMIUM_MANAGER: PremiumManager proxy address
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - PAYOUT_TOKEN: ERC-20 payout/premium token address (e.g. WETH); must already be an
 *       approved premium token on PremiumManager (set via getInitialPremiumTokens() in Deploy.s.sol)
 *
 *   Signer:
 *   - PRIVATE_KEY: Key that holds all required roles listed above
 *
 * Prerequisites:
 *   - Core contracts deployed (DeploySepolia/DeployEthereum in catalysis/core)
 *   - Coverage contracts deployed (script/DeploySepolia.s.sol)
 *   - Caller holds STAKE_MANAGER_CONFIG_ROLE, DEFAULT_ADMIN_ROLE on Core contracts,
 *     REWARDS_MANAGER_CONFIG_ROLE on RewardsManager, and DEFAULT_ADMIN_ROLE on PremiumManager
 *
 * Verify after running:
 *   cast call $STAKE_MANAGER "coverPoolFactory()(address)" --rpc-url $RPC_URL
 *   cast call $SLASHING_MANAGER "claimManager()(address)" --rpc-url $RPC_URL
 */
contract WireCoreContracts is Script {
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");

    uint256 public deployerKey;
    address public deployer;
    address public stakeManager;
    address public slashingManager;
    address public rewardsManager;
    address public sspRouter;
    address public policyManager;
    address public claimManager;
    address public premiumManager;
    address public coverPoolFactory;
    address public payoutToken;

    event WiringCompleted(
        address indexed stakeManager,
        address indexed slashingManager,
        address indexed rewardsManager,
        address coverPoolFactory,
        address policyManager,
        address claimManager,
        address premiumManager
    );

    constructor() {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        stakeManager = vm.envAddress("STAKE_MANAGER");
        slashingManager = vm.envAddress("SLASHING_MANAGER");
        rewardsManager = vm.envAddress("REWARDS_MANAGER");
        sspRouter = vm.envAddress("SSP_ROUTER");
        policyManager = vm.envAddress("POLICY_MANAGER");
        claimManager = vm.envAddress("CLAIM_MANAGER");
        premiumManager = vm.envAddress("PREMIUM_MANAGER");
        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        payoutToken = vm.envAddress("PAYOUT_TOKEN");
    }

    function run() external {
        console.log("=== CROSS-SYSTEM WIRING ===");
        console.log("Caller:", deployer);
        console.log("");
        console.log("Core contracts:");
        console.log("  StakeManager:    ", stakeManager);
        console.log("  SlashingManager: ", slashingManager);
        console.log("  RewardsManager:  ", rewardsManager);
        console.log("  SSPRouter:       ", sspRouter);
        console.log("Coverage contracts:");
        console.log("  PolicyManager:   ", policyManager);
        console.log("  ClaimManager:    ", claimManager);
        console.log("  PremiumManager:  ", premiumManager);
        console.log("  CoverPoolFactory:", coverPoolFactory);
        console.log("  PayoutToken:     ", payoutToken);

        vm.startBroadcast(deployerKey);

        console.log("\n[1/5] StakeManager.setCoverPoolFactory...");
        IStakeManagerWire(stakeManager).setCoverPoolFactory(coverPoolFactory);

        console.log("[2/5] StakeManager.grantRole(POLICY_MANAGER_ROLE, policyManager)...");
        IStakeManagerWire(stakeManager).grantRole(POLICY_MANAGER_ROLE, policyManager);

        console.log("[3/5] SlashingManager.setClaimManager...");
        ISlashingManagerWire(slashingManager).setClaimManager(claimManager);

        console.log("[4/5] RewardsManager.setPremiumManager...");
        IRewardsManagerWire(rewardsManager).setPremiumManager(premiumManager);

        console.log("[5/5] PremiumManager.approveSpender(payoutToken, sspRouter, max)...");
        IPremiumManagerWire(premiumManager).approveSpender(payoutToken, sspRouter, type(uint256).max);

        vm.stopBroadcast();

        _verify();

        console.log("\n=== CROSS-SYSTEM WIRING COMPLETED ===");
        emit WiringCompleted(
            stakeManager, slashingManager, rewardsManager, coverPoolFactory, policyManager, claimManager, premiumManager
        );
    }

    function _verify() internal view {
        console.log("\n--- Verification ---");

        address gotFactory = IStakeManagerWire(stakeManager).coverPoolFactory();
        console.log("StakeManager.coverPoolFactory:", gotFactory);
        require(gotFactory == coverPoolFactory, "StakeManager.coverPoolFactory mismatch");

        bool hasPolicyMgrRole = IStakeManagerWire(stakeManager).hasRole(POLICY_MANAGER_ROLE, policyManager);
        console.log("StakeManager.hasRole(POLICY_MANAGER_ROLE, policyManager):", hasPolicyMgrRole);
        require(hasPolicyMgrRole, "POLICY_MANAGER_ROLE not granted on StakeManager");

        address gotClaimMgr = ISlashingManagerWire(slashingManager).claimManager();
        console.log("SlashingManager.claimManager:", gotClaimMgr);
        require(gotClaimMgr == claimManager, "SlashingManager.claimManager mismatch");

        address gotPremiumMgr = IRewardsManagerWire(rewardsManager).premiumManager();
        console.log("RewardsManager.premiumManager:", gotPremiumMgr);
        require(gotPremiumMgr == premiumManager, "RewardsManager.premiumManager mismatch");

        uint256 allowance = IERC20(payoutToken).allowance(premiumManager, sspRouter);
        console.log("PremiumManager allowance for SSPRouter:", allowance);
        require(allowance == type(uint256).max, "PremiumManager.approveSpender not set");

        console.log("[SUCCESS] All 5 wiring calls verified");
    }
}
