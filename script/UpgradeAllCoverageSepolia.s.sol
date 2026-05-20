// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script, console2} from "forge-std/Script.sol";

import {Swapper} from "../src/Swapper.sol";
import {ClaimManager} from "../src/ClaimManager.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PremiumManager} from "../src/PremiumManager.sol";
import {CoverPoolFactory} from "../src/CoverPoolFactory.sol";
import {SpecRegistry} from "../src/SpecRegistry.sol";
import {CoverPool} from "../src/CoverPool.sol";

/// @dev Minimal interface — avoids importing the full contract.
interface ISwapperAdmin {
    function setClaimManager(address claimManager_) external;
}

interface ICoverPoolFactoryAdmin {
    function setCoverPoolImplementation(address implementation_) external;
}

/**
 * @title UpgradeAllCoverageSepolia
 * @notice Single-transaction orchestrator that upgrades all six Coverage UUPS proxies on Sepolia
 *         and performs all required post-upgrade wiring in one `vm.startBroadcast(admin)` block.
 *
 * @dev Upgrade sequence (proven by anvil-fork simulation):
 *   1.  Deploy 7 new implementations (Swapper, ClaimManager, PolicyManager, PremiumManager,
 *       CoverPoolFactory, SpecRegistry, CoverPool clone-target)
 *   2.  Swapper:        upgradeToAndCall(impl, "")
 *   3.  Swapper:        setClaimManager(claimManagerProxy)           ← CYS3-06 wiring
 *   4.  ClaimManager:   upgradeToAndCall(impl, initializeV2(…))      ← CYS3-03 V2 storage
 *   5.  PolicyManager:  upgradeToAndCall(impl, "")
 *   6.  PremiumManager: upgradeToAndCall(impl, "")
 *   7.  CoverPoolFactory: upgradeToAndCall(impl, "")
 *   8.  SpecRegistry:   upgradeToAndCall(impl, "")
 *   9.  CoverPoolFactory: setCoverPoolImplementation(coverPoolImpl)   ← CYS3-01 clone target
 *   10. grantRole(PAUSER_ROLE, pauser) on all 6 UUPS proxies          ← PAUSER_ROLE
 *
 * @dev Environment Variables:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (required)
 *   - ADMIN: Holder of DEFAULT_ADMIN_ROLE and CREATOR_ROLE on all proxies (Sepolia multisig)
 *            Defaults to DEPLOYER_ADDRESS
 *   - PAUSER: Address to receive PAUSER_ROLE on all six proxies (required)
 *   - ORACLE_PRICE_FEED: OraclePriceFeed proxy address (required for initializeV2)
 *   - PRICE_DEVIATION_TOLERANCE_BPS: Max DEX-vs-oracle deviation in bps (optional, default 300)
 *   - SWAPPER_PROXY: Swapper proxy address (required)
 *   - CLAIM_MANAGER_PROXY: ClaimManager proxy address (required)
 *   - POLICY_MANAGER_PROXY: PolicyManager proxy address (required)
 *   - PREMIUM_MANAGER_PROXY: PremiumManager proxy address (required)
 *   - COVER_POOL_FACTORY_PROXY: CoverPoolFactory proxy address (required)
 *   - SPEC_REGISTRY_PROXY: SpecRegistry proxy address (required)
 *
 * @dev Usage:
 *   DEPLOYER_ADDRESS=$ADMIN \
 *   ADMIN=$ADMIN \
 *   PAUSER=$PAUSER \
 *   ORACLE_PRICE_FEED=0x57F750E3B8e095A5b3AE96030F0cac5dFe2f8A16 \
 *   PRICE_DEVIATION_TOLERANCE_BPS=300 \
 *   SWAPPER_PROXY=0x148Bfe2330cEe4f227addb47736a105DB427dc31 \
 *   CLAIM_MANAGER_PROXY=0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45 \
 *   POLICY_MANAGER_PROXY=0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
 *   PREMIUM_MANAGER_PROXY=0xEc7322D6754709d5001B710ec4fB2547a89B3aD1 \
 *   COVER_POOL_FACTORY_PROXY=0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66 \
 *   SPEC_REGISTRY_PROXY=0x90EfF742958dd4c54ede3ED365375a14077D0A58 \
 *     forge script script/UpgradeAllCoverageSepolia.s.sol --broadcast \
 *     --rpc-url $SEPOLIA_RPC_URL --keystore $KEYSTORE --sender $ADMIN
 */
contract UpgradeAllCoverageSepolia is Script {
    struct Proxies {
        address swapper;
        address claimManager;
        address policyManager;
        address premiumManager;
        address coverPoolFactory;
        address specRegistry;
    }

    struct Impls {
        address swapper;
        address claimManager;
        address policyManager;
        address premiumManager;
        address coverPoolFactory;
        address specRegistry;
        address coverPool;
    }

    function run() external {
        require(block.chainid == 11_155_111, "Must run on Sepolia");

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address admin = vm.envOr("ADMIN", deployer);
        address pauser = vm.envAddress("PAUSER");
        address oraclePriceFeed = vm.envAddress("ORACLE_PRICE_FEED");
        uint16 toleranceBps = SafeCast.toUint16(vm.envOr("PRICE_DEVIATION_TOLERANCE_BPS", uint256(300)));

        Proxies memory proxies = _loadProxies();

        console2.log("");
        console2.log("=== UpgradeAllCoverageSepolia ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Admin:", admin);
        console2.log("Pauser:", pauser);
        console2.log("OraclePriceFeed:", oraclePriceFeed);
        console2.log("PriceDeviationToleranceBps:", toleranceBps);
        console2.log("");

        vm.startBroadcast(admin);

        Impls memory impls = _deployImplementations();

        _upgradeProxies(proxies, impls, oraclePriceFeed, toleranceBps);

        _grantPauserRole(proxies, pauser);

        vm.stopBroadcast();

        _logSummary(proxies, impls);
    }

    function _loadProxies() internal view returns (Proxies memory p) {
        p.swapper = vm.envAddress("SWAPPER_PROXY");
        p.claimManager = vm.envAddress("CLAIM_MANAGER_PROXY");
        p.policyManager = vm.envAddress("POLICY_MANAGER_PROXY");
        p.premiumManager = vm.envAddress("PREMIUM_MANAGER_PROXY");
        p.coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY_PROXY");
        p.specRegistry = vm.envAddress("SPEC_REGISTRY_PROXY");
    }

    function _deployImplementations() internal returns (Impls memory i) {
        console2.log("--- Deploying implementations ---");

        i.swapper = address(new Swapper());
        console2.log("Swapper impl:           ", i.swapper);

        i.claimManager = address(new ClaimManager());
        console2.log("ClaimManager impl:      ", i.claimManager);

        i.policyManager = address(new PolicyManager());
        console2.log("PolicyManager impl:     ", i.policyManager);

        i.premiumManager = address(new PremiumManager());
        console2.log("PremiumManager impl:    ", i.premiumManager);

        i.coverPoolFactory = address(new CoverPoolFactory());
        console2.log("CoverPoolFactory impl:  ", i.coverPoolFactory);

        i.specRegistry = address(new SpecRegistry());
        console2.log("SpecRegistry impl:      ", i.specRegistry);

        i.coverPool = address(new CoverPool());
        console2.log("CoverPool clone-target: ", i.coverPool);

        console2.log("");
    }

    function _upgradeProxies(Proxies memory p, Impls memory i, address oraclePriceFeed, uint16 toleranceBps) internal {
        console2.log("--- Upgrading proxies ---");

        // Step 1: Swapper — introduces claimManager slot, lockRouteUntil, PAUSER_ROLE
        UUPSUpgradeable(p.swapper).upgradeToAndCall(i.swapper, "");
        console2.log("[1] Swapper upgraded");

        // Step 2: Wire Swapper.claimManager BEFORE upgrading ClaimManager or PolicyManager.
        //         Without this, bindPolicy reverts OnlyClaimManager for any cross-token policy.
        ISwapperAdmin(p.swapper).setClaimManager(p.claimManager);
        console2.log("[2] Swapper.setClaimManager ->", p.claimManager);

        // Step 3: ClaimManager — atomically calls initializeV2 to write oraclePriceFeed + toleranceBps
        bytes memory initV2 = abi.encodeCall(ClaimManager.initializeV2, (oraclePriceFeed, toleranceBps));
        UUPSUpgradeable(p.claimManager).upgradeToAndCall(i.claimManager, initV2);
        console2.log("[3] ClaimManager upgraded + initializeV2 called");

        // Step 4: PolicyManager — renames chainlinkPriceFeed -> oraclePriceFeed, new bindPolicy logic
        UUPSUpgradeable(p.policyManager).upgradeToAndCall(i.policyManager, "");
        console2.log("[4] PolicyManager upgraded");

        // Steps 5-7: Remaining proxies (PAUSER_ROLE only, order-independent)
        UUPSUpgradeable(p.premiumManager).upgradeToAndCall(i.premiumManager, "");
        console2.log("[5] PremiumManager upgraded");

        UUPSUpgradeable(p.coverPoolFactory).upgradeToAndCall(i.coverPoolFactory, "");
        console2.log("[6] CoverPoolFactory upgraded");

        UUPSUpgradeable(p.specRegistry).upgradeToAndCall(i.specRegistry, "");
        console2.log("[7] SpecRegistry upgraded");

        // Step 8: Update CoverPool clone-target so new pools get CYS3-01 USD-conversion fix.
        //         Requires CREATOR_ROLE (held by admin/multisig on both Sepolia and mainnet).
        //         NOTE: Existing pool clones are EIP-1167 minimal proxies and cannot be upgraded.
        ICoverPoolFactoryAdmin(p.coverPoolFactory).setCoverPoolImplementation(i.coverPool);
        console2.log("[8] CoverPoolFactory.setCoverPoolImplementation ->", i.coverPool);

        console2.log("");
    }

    function _grantPauserRole(Proxies memory p, address pauser) internal {
        console2.log("--- Granting PAUSER_ROLE ---");

        bytes32 pauserRole = keccak256("PAUSER_ROLE");

        IAccessControl(p.swapper).grantRole(pauserRole, pauser);
        console2.log("PAUSER_ROLE granted on Swapper");

        IAccessControl(p.claimManager).grantRole(pauserRole, pauser);
        console2.log("PAUSER_ROLE granted on ClaimManager");

        IAccessControl(p.policyManager).grantRole(pauserRole, pauser);
        console2.log("PAUSER_ROLE granted on PolicyManager");

        IAccessControl(p.premiumManager).grantRole(pauserRole, pauser);
        console2.log("PAUSER_ROLE granted on PremiumManager");

        IAccessControl(p.coverPoolFactory).grantRole(pauserRole, pauser);
        console2.log("PAUSER_ROLE granted on CoverPoolFactory");

        IAccessControl(p.specRegistry).grantRole(pauserRole, pauser);
        console2.log("PAUSER_ROLE granted on SpecRegistry");

        console2.log("");
    }

    function _logSummary(Proxies memory p, Impls memory i) internal view {
        console2.log("=== Upgrade Complete ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("");
        console2.log("--- New Implementations ---");
        console2.log("Swapper:           proxy=", p.swapper, " impl=", i.swapper);
        console2.log("ClaimManager:      proxy=", p.claimManager, " impl=", i.claimManager);
        console2.log("PolicyManager:     proxy=", p.policyManager, " impl=", i.policyManager);
        console2.log("PremiumManager:    proxy=", p.premiumManager, " impl=", i.premiumManager);
        console2.log("CoverPoolFactory:  proxy=", p.coverPoolFactory, " impl=", i.coverPoolFactory);
        console2.log("SpecRegistry:      proxy=", p.specRegistry, " impl=", i.specRegistry);
        console2.log("CoverPool target:  (clone-target)", i.coverPool);
        console2.log("");
        console2.log("Run VerifySepoliaConfig to confirm all wiring is correct:");
        console2.log("  forge script script/VerifySepoliaConfig.s.sol --rpc-url $SEPOLIA_RPC_URL");
        console2.log("====================================");
    }
}
