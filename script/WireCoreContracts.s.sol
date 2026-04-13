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

interface ISSPRouterWire {
    function setStakeRecipient(address _stakeRecipient) external;
    function stakeRecipient() external view returns (address);
}

interface IRewardsManagerWire {
    function setPremiumManager(address _premiumManager) external;
    function premiumManager() external view returns (address);
}

interface IPremiumManagerWire {
    function approveSpender(address token, address spender, uint256 amount) external;
    function CLAIM_MANAGER_ROLE() external view returns (bytes32);
}

interface IClaimManagerWire {
    function setPremiumManager(address premiumManager_) external;
}

interface IAccessControlGrant {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IClaimManagerPremiumView {
    function premiumManager() external view returns (address);
}

/**
 * @title WireCoreContracts
 * @notice Performs all cross-system wiring between Catalysis Core and Coverage contracts.
 * @dev Must be run after both Core and Coverage contracts are deployed.
 *      Executes eight calls that bridge the two systems:
 *
 *      1. StakeManager.setCoverPoolFactory    — unblocks createCommittee() during requestCoverage()
 *      2. StakeManager.grantRole(POLICY_MANAGER_ROLE, policyManager) — unblocks requestCoverage()
 *      3. SlashingManager.setClaimManager     — grants CLAIM_MANAGER_ROLE, unblocks executeSlashing()
 *      4. RewardsManager.setPremiumManager    — grants PREMIUM_MANAGER_ROLE, unblocks distributeRewards()
 *      5. PremiumManager.approveSpender       — allows RewardsManager to pull the restaker share
 *                                               from PremiumManager via safeTransferFrom; required
 *                                               for distributeRewards() to route rewards correctly
 *      6. ClaimManager.setPremiumManager      — routes claim surplus through PremiumManager.
 *      7. PremiumManager.grantRole(CLAIM_MANAGER_ROLE, claimManager)
 *                                            — allows ClaimManager to call distributeSurplusAsRewards().
 *      8. SSPRouter.setStakeRecipient         — sets the EigenLayer redistribution recipient so
 *                                               slashed collateral flows to ClaimManager, not the
 *                                               deployer; must run before any committee is created
 *
 *      Role requirements (all held by the ADMIN after Core and Coverage deploys):
 *        - STAKE_MANAGER_CONFIG_ROLE on StakeManager     (defaults to ADMIN)
 *        - DEFAULT_ADMIN_ROLE on StakeManager
 *        - DEFAULT_ADMIN_ROLE on SlashingManager
 *        - REWARDS_MANAGER_CONFIG_ROLE on RewardsManager (defaults to ADMIN)
 *        - DEFAULT_ADMIN_ROLE on PremiumManager, ClaimManager, and other Coverage proxies
 *        - DEFAULT_ADMIN_ROLE on SSPRouter
 *
 *      On testnet (ADMIN == DEPLOYER_ADDRESS): the deployer keystore covers all 6 calls.
 *      On mainnet (ADMIN is a multisig): omit --broadcast; submit the calldata batch via Safe.
 *
 * Usage:
 *   Testnet (ADMIN == DEPLOYER_ADDRESS):
 *     forge script script/WireCoreContracts.s.sol:WireCoreContracts \
 *       --rpc-url $RPC_URL --broadcast --slow -vvvv \
 *       --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 *   Mainnet (ADMIN is a multisig — no keystore or broadcast needed):
 *     forge script script/WireCoreContracts.s.sol:WireCoreContracts \
 *       --rpc-url $RPC_URL --slow -vvvv
 *     (no --broadcast, no --keystore; bundle the 6 printed calldatas into a Safe multi-send batch)
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
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *   - ADMIN: Address that holds all required roles. Defaults to DEPLOYER_ADDRESS.
 *            On mainnet this is the Gnosis Safe multisig — omit --broadcast and submit via Safe.
 *
 * Prerequisites:
 *   - Core contracts deployed (DeploySepolia/DeployEthereum in catalysis/core)
 *   - Coverage contracts deployed (script/DeploySepolia.s.sol)
 *   - ADMIN holds STAKE_MANAGER_CONFIG_ROLE and DEFAULT_ADMIN_ROLE on Core contracts,
 *     REWARDS_MANAGER_CONFIG_ROLE on RewardsManager, DEFAULT_ADMIN_ROLE on PremiumManager,
 *     and DEFAULT_ADMIN_ROLE on SSPRouter
 *
 * Verify after running:
 *   cast call $STAKE_MANAGER "coverPoolFactory()(address)" --rpc-url $RPC_URL
 *   cast call $SLASHING_MANAGER "claimManager()(address)" --rpc-url $RPC_URL
 *   cast call $SSP_ROUTER "stakeRecipient()(address)" --rpc-url $RPC_URL
 */
contract WireCoreContracts is Script {
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");

    address public deployer;
    /// @notice Holder of all required roles. Defaults to deployer. On mainnet: ADMIN multisig.
    address public admin;
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
        address sspRouter,
        address coverPoolFactory,
        address policyManager,
        address claimManager,
        address premiumManager
    );

    constructor() {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        admin = vm.envOr("ADMIN", deployer);
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
        console.log("Keystore signer (deployer):", deployer);
        console.log("Broadcaster (admin / role holder):", admin);
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

        // All 6 calls require roles held by admin (DEFAULT_ADMIN_ROLE or config roles that default to ADMIN).
        // On testnet admin == deployer; on mainnet admin is the multisig — omit --broadcast and use Safe.
        vm.startBroadcast(admin);

        console.log("\n[1/8] StakeManager.setCoverPoolFactory...");
        IStakeManagerWire(stakeManager).setCoverPoolFactory(coverPoolFactory);

        console.log("[2/8] StakeManager.grantRole(POLICY_MANAGER_ROLE, policyManager)...");
        IStakeManagerWire(stakeManager).grantRole(POLICY_MANAGER_ROLE, policyManager);

        console.log("[3/8] SlashingManager.setClaimManager...");
        ISlashingManagerWire(slashingManager).setClaimManager(claimManager);

        console.log("[4/8] RewardsManager.setPremiumManager...");
        IRewardsManagerWire(rewardsManager).setPremiumManager(premiumManager);

        console.log("[5/8] PremiumManager.approveSpender(payoutToken, rewardsManager, max)...");
        IPremiumManagerWire(premiumManager).approveSpender(payoutToken, rewardsManager, type(uint256).max);

        console.log("[6/8] ClaimManager.setPremiumManager...");
        IClaimManagerWire(claimManager).setPremiumManager(premiumManager);

        bytes32 claimManagerRoleOnPremium = IPremiumManagerWire(premiumManager).CLAIM_MANAGER_ROLE();
        console.log("[7/8] PremiumManager.grantRole(CLAIM_MANAGER_ROLE, claimManager)...");
        IAccessControlGrant(premiumManager).grantRole(claimManagerRoleOnPremium, claimManager);

        console.log("[8/8] SSPRouter.setStakeRecipient(claimManager)...");
        ISSPRouterWire(sspRouter).setStakeRecipient(claimManager);

        vm.stopBroadcast();

        _verify();

        console.log("\n=== CROSS-SYSTEM WIRING COMPLETED ===");
        emit WiringCompleted(
            stakeManager,
            slashingManager,
            rewardsManager,
            sspRouter,
            coverPoolFactory,
            policyManager,
            claimManager,
            premiumManager
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

        uint256 allowance = IERC20(payoutToken).allowance(premiumManager, rewardsManager);
        console.log("PremiumManager allowance for RewardsManager:", allowance);
        require(allowance == type(uint256).max, "PremiumManager.approveSpender not set");

        address gotCmPremium = IClaimManagerPremiumView(claimManager).premiumManager();
        console.log("ClaimManager.premiumManager:", gotCmPremium);
        require(gotCmPremium == premiumManager, "ClaimManager.premiumManager mismatch");

        bytes32 cmRole = IPremiumManagerWire(premiumManager).CLAIM_MANAGER_ROLE();
        bool claimMgrHasRole = IAccessControlGrant(premiumManager).hasRole(cmRole, claimManager);
        console.log("PremiumManager.hasRole(CLAIM_MANAGER_ROLE, claimManager):", claimMgrHasRole);
        require(claimMgrHasRole, "CLAIM_MANAGER_ROLE not granted on PremiumManager");

        address gotStakeRecipient = ISSPRouterWire(sspRouter).stakeRecipient();
        console.log("SSPRouter.stakeRecipient:", gotStakeRecipient);
        require(gotStakeRecipient == claimManager, "SSPRouter.stakeRecipient mismatch");

        console.log("[SUCCESS] All 8 wiring calls verified");
    }
}
