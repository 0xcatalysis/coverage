// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

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
 *      6. ClaimManager.setPremiumManager      — routes claim surplus through PremiumManager
 *      7. PremiumManager.grantRole(CLAIM_MANAGER_ROLE, claimManager)
 *                                            — allows ClaimManager to call distributeSurplusAsRewards()
 *      8. SSPRouter.setStakeRecipient         — sets the EigenLayer redistribution recipient so
 *                                               slashed collateral flows to ClaimManager, not the
 *                                               deployer; must run before any committee is created
 *
 *      Role requirements — two groups with different signers on mainnet:
 *
 *        Calls 1, 2, 3, 4, 8 — Core / SSPRouter contracts; ADMIN holds required roles directly:
 *          - STAKE_MANAGER_CONFIG_ROLE on StakeManager     (defaults to ADMIN)
 *          - DEFAULT_ADMIN_ROLE on StakeManager
 *          - DEFAULT_ADMIN_ROLE on SlashingManager
 *          - REWARDS_MANAGER_CONFIG_ROLE on RewardsManager (defaults to ADMIN)
 *          - DEFAULT_ADMIN_ROLE on SSPRouter
 *
 *        Calls 5, 6, 7 — Coverage contracts; DEFAULT_ADMIN_ROLE held by TimelockController (mainnet):
 *          - DEFAULT_ADMIN_ROLE on PremiumManager   (ADMIN direct on testnet; TIMELOCK on mainnet)
 *          - DEFAULT_ADMIN_ROLE on ClaimManager     (ADMIN direct on testnet; TIMELOCK on mainnet)
 *
 *      When TIMELOCK is not set (testnet, ADMIN == DEPLOYER_ADDRESS):
 *        All 8 calls broadcast in a single block from the deployer keystore.
 *
 *      When TIMELOCK is set (mainnet):
 *        Calls 1, 2, 3, 4, 8: simulated without --broadcast; copy printed calldatas to Safe multi-send.
 *        Calls 5, 6, 7: printed as scheduleBatch + executeBatch calldatas for TimelockController.
 *          Step 1 — Submit scheduleBatch calldata via Safe TX Builder now.
 *          Step 2 — After minDelay elapses, submit executeBatch calldata via Safe TX Builder.
 *
 * Usage (testnet, TIMELOCK not set):
 *   forge script script/WireCoreContracts.s.sol:WireCoreContracts \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv \
 *     --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 * Usage (mainnet, TIMELOCK set):
 *   forge script script/WireCoreContracts.s.sol:WireCoreContracts \
 *     --rpc-url $RPC_URL --slow -vvvv --sender $ADMIN
 *   (no --broadcast; copy the 5 Core call calldatas to a Safe multi-send batch)
 *   (copy the printed scheduleBatch calldata and submit to TimelockController via Safe TX Builder)
 *   (after minDelay, submit the executeBatch calldata via Safe TX Builder)
 *
 * Required Environment Variables:
 *   Core (from DeploySepolia/DeployEthereum outputs):
 *   - STAKE_MANAGER: StakeManager proxy address
 *   - SLASHING_MANAGER: SlashingManager proxy address
 *   - REWARDS_MANAGER: RewardsManager proxy address
 *   - SSP_ROUTER: SSPRouter proxy address
 *
 *   Coverage (from script/Deploy.s.sol outputs):
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - CLAIM_MANAGER: ClaimManager proxy address
 *   - PREMIUM_MANAGER: PremiumManager proxy address
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - PAYOUT_TOKEN: ERC-20 payout/premium token address (e.g. WETH); must already be an
 *       approved premium token on PremiumManager (set via getInitialPremiumTokens() in Deploy.s.sol)
 *
 *   Signer:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore on testnet).
 *   - ADMIN: Address that holds all required roles on Core/SSPRouter contracts and is
 *            proposer/executor on TimelockController. Defaults to DEPLOYER_ADDRESS.
 *   - TIMELOCK (optional): TimelockController address (fill in after Phase 2 on mainnet).
 *            When set, calls 5/6/7 are routed through the timelock.
 *
 * Prerequisites:
 *   - Core contracts deployed (DeploySepolia/DeployEthereum in catalysis/core)
 *   - Coverage contracts deployed (script/Deploy.s.sol)
 *   - ADMIN holds required roles on Core / SSPRouter contracts
 *   - TimelockController (TIMELOCK) holds DEFAULT_ADMIN_ROLE on Coverage contracts (mainnet)
 *
 * Verify after running (after timelock execute on mainnet):
 *   cast call $STAKE_MANAGER "coverPoolFactory()(address)" --rpc-url $RPC_URL
 *   cast call $SLASHING_MANAGER "claimManager()(address)" --rpc-url $RPC_URL
 *   cast call $SSP_ROUTER "stakeRecipient()(address)" --rpc-url $RPC_URL
 */
contract WireCoreContracts is Script {
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");

    address public deployer;
    /// @notice Holder of required roles on Core/SSPRouter. Proposer/executor on TimelockController.
    address public admin;
    /// @notice TimelockController address. When set, calls 5/6/7 are routed through the timelock.
    address public timelock;
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
        timelock = vm.envOr("TIMELOCK", address(0));
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
        console.log("TimelockController:", timelock);
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

        if (timelock != address(0)) {
            _runWithTimelock();
        } else {
            _runDirect();
        }
    }

    // ─── Direct path (testnet / no timelock)
    // ────────────────────────────────────

    /**
     * @notice Direct path (testnet / no timelock): broadcasts all 8 wiring calls from admin.
     * @dev ADMIN must hold DEFAULT_ADMIN_ROLE on Coverage contracts directly.
     */
    function _runDirect() private {
        // All 8 calls require roles held by admin.
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

        _verifyAll();

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

    // ─── Timelock path (mainnet)
    // ────────────────────────────────────────────────

    /**
     * @notice Timelock path (mainnet): Core calls simulated for Safe batch; Coverage calls
     *         printed as scheduleBatch / executeBatch calldata for TimelockController.
     * @dev Calls 1, 2, 3, 4, 8 target Core/SSPRouter contracts where ADMIN holds the required
     *      roles directly. Run without --broadcast; copy the printed calldatas into a Safe
     *      multi-send batch.
     *
     *      Calls 5, 6, 7 target Coverage contracts where DEFAULT_ADMIN_ROLE is held by
     *      TimelockController. These are printed as scheduleBatch + executeBatch calldata:
     *        Step 1 — Submit scheduleBatch to TimelockController via Safe TX Builder.
     *        Step 2 — After minDelay elapses, submit executeBatch via Safe TX Builder.
     *
     *      Wiring is INCOMPLETE until the timelock execute is confirmed. Do NOT proceed to
     *      Phase 3b until coverage call verification passes.
     */
    function _runWithTimelock() private {
        // ── Core calls (1, 2, 3, 4, 8): ADMIN holds required roles directly
        // ──────────────────
        // Run without --broadcast; Foundry simulation prints calldatas for the Safe multi-send.
        vm.startBroadcast(admin);

        console.log("\n[1/8] StakeManager.setCoverPoolFactory...");
        IStakeManagerWire(stakeManager).setCoverPoolFactory(coverPoolFactory);

        console.log("[2/8] StakeManager.grantRole(POLICY_MANAGER_ROLE, policyManager)...");
        IStakeManagerWire(stakeManager).grantRole(POLICY_MANAGER_ROLE, policyManager);

        console.log("[3/8] SlashingManager.setClaimManager...");
        ISlashingManagerWire(slashingManager).setClaimManager(claimManager);

        console.log("[4/8] RewardsManager.setPremiumManager...");
        IRewardsManagerWire(rewardsManager).setPremiumManager(premiumManager);

        console.log("[8/8] SSPRouter.setStakeRecipient(claimManager)...");
        ISSPRouterWire(sspRouter).setStakeRecipient(claimManager);

        vm.stopBroadcast();

        // ── Coverage calls (5, 6, 7): DEFAULT_ADMIN_ROLE held by TimelockController
        // ────────────
        // Calldata has been printed below; submit via Safe TX Builder.
        // Do NOT emit WiringCompleted — wiring is incomplete until the timelock executes.
        _printCoverageTimelockCalldata();
    }

    /**
     * @notice Prints scheduleBatch + executeBatch calldata for Coverage wiring calls 5, 6, 7.
     * @dev Coverage calls require DEFAULT_ADMIN_ROLE on PremiumManager and ClaimManager.
     *      On mainnet this role is held by the TimelockController, so these calls must be
     *      scheduled and executed via the timelock rather than called directly by ADMIN.
     */
    function _printCoverageTimelockCalldata() private view {
        bytes32 cmRole = IPremiumManagerWire(premiumManager).CLAIM_MANAGER_ROLE();
        uint256 minDelay = TimelockController(payable(timelock)).getMinDelay();

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory calldatas = new bytes[](3);

        // Call 5: PremiumManager.approveSpender(payoutToken, rewardsManager, max)
        targets[0] = premiumManager;
        values[0] = 0;
        calldatas[0] =
            abi.encodeCall(IPremiumManagerWire.approveSpender, (payoutToken, rewardsManager, type(uint256).max));

        // Call 6: ClaimManager.setPremiumManager(premiumManager)
        targets[1] = claimManager;
        values[1] = 0;
        calldatas[1] = abi.encodeCall(IClaimManagerWire.setPremiumManager, (premiumManager));

        // Call 7: PremiumManager.grantRole(CLAIM_MANAGER_ROLE, claimManager)
        targets[2] = premiumManager;
        values[2] = 0;
        calldatas[2] = abi.encodeCall(IAccessControlGrant.grantRole, (cmRole, claimManager));

        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.scheduleBatch, (targets, values, calldatas, bytes32(0), bytes32(0), minDelay)
        );
        bytes memory executeCalldata =
            abi.encodeCall(TimelockController.executeBatch, (targets, values, calldatas, bytes32(0), bytes32(0)));

        console2.log("");
        console2.log("--- Coverage Wiring Calldata (submit via Safe TX Builder) ---");
        console2.log("Calls 5/6/7 require DEFAULT_ADMIN_ROLE on Coverage contracts, held by TimelockController.");
        console2.log("TimelockController:", timelock);
        console2.log("Min Delay:", minDelay, "seconds");
        console2.log("");
        console2.log("Step 1 - Schedule (submit now):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(scheduleCalldata));
        console2.log("");
        console2.log("Step 2 - Execute (submit after delay):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(executeCalldata));
        console2.log("=============================================================");
    }

    // ─── Verification
    // ───────────────────────────────────────────────────────────

    function _verifyAll() internal view {
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
