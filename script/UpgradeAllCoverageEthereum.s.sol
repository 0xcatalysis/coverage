// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script, console2} from "forge-std/Script.sol";

import {Swapper} from "../src/Swapper.sol";
import {ClaimManager} from "../src/ClaimManager.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PremiumManager} from "../src/PremiumManager.sol";
import {CoverPoolFactory} from "../src/CoverPoolFactory.sol";
import {SpecRegistry} from "../src/SpecRegistry.sol";
import {CoverPool} from "../src/CoverPool.sol";

/**
 * @title UpgradeAllCoverageEthereum
 * @notice Hybrid upgrade orchestrator for Coverage contracts on Ethereum mainnet.
 *
 * @dev Two-phase execution:
 *
 *   Phase 1 (broadcast from deployer EOA):
 *     Deploys 7 new implementations (Swapper, ClaimManager, PolicyManager, PremiumManager,
 *     CoverPoolFactory, SpecRegistry, CoverPool clone-target).
 *
 *   Phase 2 (Safe TX Builder, multisig → TimelockController — min delay 2 days):
 *     Prints scheduleBatch + executeBatch calldata for 13 calls through the Timelock.
 *     Also prints a separate immediate multisig call for setCoverPoolImplementation
 *     (CREATOR_ROLE is held by the multisig directly, not the Timelock).
 *
 *   13-call Timelock batch:
 *     1.  Swapper.upgradeToAndCall(swapperImpl, "")
 *     2.  Swapper.setClaimManager(claimManagerProxy)      <- CYS3-06 MANDATORY
 *     3.  ClaimManager.upgradeToAndCall(impl, initializeV2(oraclePriceFeed, toleranceBps))
 *     4.  PolicyManager.upgradeToAndCall(impl, "")
 *     5.  PremiumManager.upgradeToAndCall(impl, "")
 *     6.  CoverPoolFactory.upgradeToAndCall(impl, "")
 *     7.  SpecRegistry.upgradeToAndCall(impl, "")
 *     8-13. grantRole(PAUSER_ROLE, pauser) on each of the 6 proxies
 *
 *   Separate immediate multisig call:
 *     CoverPoolFactory.setCoverPoolImplementation(coverPoolImpl)
 *
 * @dev Prerequisites:
 *   forge clean && forge build
 *   forge test --match-contract StorageLayoutTest -vvv
 *
 * @dev Environment Variables:
 *   DEPLOYER_ADDRESS, TIMELOCK, ADMIN, PAUSER, ORACLE_PRICE_FEED,
 *   PRICE_DEVIATION_TOLERANCE_BPS (default 300),
 *   SWAPPER_PROXY, CLAIM_MANAGER_PROXY, POLICY_MANAGER_PROXY,
 *   PREMIUM_MANAGER_PROXY, COVER_POOL_FACTORY_PROXY, SPEC_REGISTRY_PROXY
 *
 * @dev Usage:
 *   DEPLOYER_ADDRESS=<deployer> \
 *   TIMELOCK=0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7 \
 *   ADMIN=0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c \
 *   PAUSER=<pauser-bot> \
 *   ORACLE_PRICE_FEED=0x57F750E3B8e095A5b3AE96030F0cac5dFe2f8A16 \
 *   PRICE_DEVIATION_TOLERANCE_BPS=300 \
 *   SWAPPER_PROXY=0x148Bfe2330cEe4f227addb47736a105DB427dc31 \
 *   CLAIM_MANAGER_PROXY=0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45 \
 *   POLICY_MANAGER_PROXY=0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
 *   PREMIUM_MANAGER_PROXY=0xEc7322D6754709d5001B710ec4fB2547a89B3aD1 \
 *   COVER_POOL_FACTORY_PROXY=0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66 \
 *   SPEC_REGISTRY_PROXY=0x90EfF742958dd4c54ede3ED365375a14077D0A58 \
 *     forge script script/UpgradeAllCoverageEthereum.s.sol --broadcast \
 *     --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 */
contract UpgradeAllCoverageEthereum is Script {
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant ZERO = bytes32(0);

    address internal _swapperImpl;
    address internal _claimManagerImpl;
    address internal _policyManagerImpl;
    address internal _premiumManagerImpl;
    address internal _coverPoolFactoryImpl;
    address internal _specRegistryImpl;
    address internal _coverPoolImpl;

    address internal _swapperProxy;
    address internal _claimManagerProxy;
    address internal _policyManagerProxy;
    address internal _premiumManagerProxy;
    address internal _coverPoolFactoryProxy;
    address internal _specRegistryProxy;

    function run() external {
        require(block.chainid == 1, "Must run on Ethereum mainnet");

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK");
        address admin = vm.envAddress("ADMIN");
        address pauser = vm.envAddress("PAUSER");
        address oraclePriceFeed = vm.envAddress("ORACLE_PRICE_FEED");
        uint16 toleranceBps = SafeCast.toUint16(vm.envOr("PRICE_DEVIATION_TOLERANCE_BPS", uint256(300)));

        _swapperProxy = vm.envAddress("SWAPPER_PROXY");
        _claimManagerProxy = vm.envAddress("CLAIM_MANAGER_PROXY");
        _policyManagerProxy = vm.envAddress("POLICY_MANAGER_PROXY");
        _premiumManagerProxy = vm.envAddress("PREMIUM_MANAGER_PROXY");
        _coverPoolFactoryProxy = vm.envAddress("COVER_POOL_FACTORY_PROXY");
        _specRegistryProxy = vm.envAddress("SPEC_REGISTRY_PROXY");

        console2.log("");
        console2.log("=== UpgradeAllCoverageEthereum ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Admin (multisig):", admin);
        console2.log("Timelock:", timelock);
        console2.log("Pauser:", pauser);
        console2.log("");

        // Phase 1: deployer deploys implementations
        vm.startBroadcast(deployer);
        _deployImplementations();
        vm.stopBroadcast();

        // Phase 2: print Timelock batch calldata
        uint256 minDelay = TimelockController(payable(timelock)).getMinDelay();
        _printBatch(timelock, oraclePriceFeed, toleranceBps, pauser, minDelay);
        _printImmediateCall(admin);
    }

    function _deployImplementations() internal {
        console2.log("--- Phase 1: Deploying implementations ---");

        _swapperImpl = address(new Swapper());
        console2.log("Swapper impl:           ", _swapperImpl);

        _claimManagerImpl = address(new ClaimManager());
        console2.log("ClaimManager impl:      ", _claimManagerImpl);

        _policyManagerImpl = address(new PolicyManager());
        console2.log("PolicyManager impl:     ", _policyManagerImpl);

        _premiumManagerImpl = address(new PremiumManager());
        console2.log("PremiumManager impl:    ", _premiumManagerImpl);

        _coverPoolFactoryImpl = address(new CoverPoolFactory());
        console2.log("CoverPoolFactory impl:  ", _coverPoolFactoryImpl);

        _specRegistryImpl = address(new SpecRegistry());
        console2.log("SpecRegistry impl:      ", _specRegistryImpl);

        _coverPoolImpl = address(new CoverPool());
        console2.log("CoverPool clone-target: ", _coverPoolImpl);

        console2.log("");
    }

    function _buildTargets() internal view returns (address[] memory targets) {
        targets = new address[](13);
        targets[0] = _swapperProxy;
        targets[1] = _swapperProxy;
        targets[2] = _claimManagerProxy;
        targets[3] = _policyManagerProxy;
        targets[4] = _premiumManagerProxy;
        targets[5] = _coverPoolFactoryProxy;
        targets[6] = _specRegistryProxy;
        targets[7] = _swapperProxy;
        targets[8] = _claimManagerProxy;
        targets[9] = _policyManagerProxy;
        targets[10] = _premiumManagerProxy;
        targets[11] = _coverPoolFactoryProxy;
        targets[12] = _specRegistryProxy;
    }

    function _buildPayloads(
        address oraclePriceFeed,
        uint16 toleranceBps,
        address pauser
    )
        internal
        view
        returns (bytes[] memory payloads)
    {
        payloads = new bytes[](13);
        bytes memory gr = abi.encodeCall(IAccessControl.grantRole, (PAUSER_ROLE, pauser));
        bytes memory initV2 = abi.encodeCall(ClaimManager.initializeV2, (oraclePriceFeed, toleranceBps));

        payloads[0] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_swapperImpl, ""));
        payloads[1] = abi.encodeWithSignature("setClaimManager(address)", _claimManagerProxy);
        payloads[2] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_claimManagerImpl, initV2));
        payloads[3] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_policyManagerImpl, ""));
        payloads[4] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_premiumManagerImpl, ""));
        payloads[5] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_coverPoolFactoryImpl, ""));
        payloads[6] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_specRegistryImpl, ""));
        payloads[7] = gr;
        payloads[8] = gr;
        payloads[9] = gr;
        payloads[10] = gr;
        payloads[11] = gr;
        payloads[12] = gr;
    }

    function _printBatch(
        address timelock,
        address oraclePriceFeed,
        uint16 toleranceBps,
        address pauser,
        uint256 minDelay
    )
        internal
        view
    {
        address[] memory targets = _buildTargets();
        uint256[] memory values = new uint256[](13);
        bytes[] memory payloads = _buildPayloads(oraclePriceFeed, toleranceBps, pauser);

        bytes memory schedData =
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, ZERO, ZERO, minDelay));
        bytes memory execData = abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, ZERO, ZERO));
        bytes32 opId = keccak256(abi.encode(targets, values, payloads, ZERO, ZERO));

        console2.log("--- Phase 2: Safe TX Builder Calldata (13-call Timelock batch) ---");
        console2.log("TimelockController:", timelock);
        console2.log("Min Delay (seconds):", minDelay);
        console2.log("Min Delay (days):", minDelay / 86_400);
        console2.log("Operation ID:", vm.toString(opId));
        console2.log("");
        console2.log("Batch call breakdown:");
        console2.log("  [ 1] Swapper.upgradeToAndCall:", _swapperImpl);
        console2.log("  [ 2] Swapper.setClaimManager:", _claimManagerProxy, " <- CYS3-06");
        console2.log("  [ 3] ClaimManager.upgradeToAndCall:", _claimManagerImpl, " + initializeV2");
        console2.log("  [ 4] PolicyManager.upgradeToAndCall:", _policyManagerImpl);
        console2.log("  [ 5] PremiumManager.upgradeToAndCall:", _premiumManagerImpl);
        console2.log("  [ 6] CoverPoolFactory.upgradeToAndCall:", _coverPoolFactoryImpl);
        console2.log("  [ 7] SpecRegistry.upgradeToAndCall:", _specRegistryImpl);
        console2.log("  [ 8] Swapper.grantRole(PAUSER_ROLE):", pauser);
        console2.log("  [ 9] ClaimManager.grantRole(PAUSER_ROLE):", pauser);
        console2.log("  [10] PolicyManager.grantRole(PAUSER_ROLE):", pauser);
        console2.log("  [11] PremiumManager.grantRole(PAUSER_ROLE):", pauser);
        console2.log("  [12] CoverPoolFactory.grantRole(PAUSER_ROLE):", pauser);
        console2.log("  [13] SpecRegistry.grantRole(PAUSER_ROLE):", pauser);
        console2.log("");
        console2.log("Step 1 - scheduleBatch:");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(schedData));
        console2.log("");
        console2.log("Step 2 - executeBatch (after delay elapsed):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(execData));
        console2.log("");
        console2.log("Monitor: cast call", timelock, "'isOperationReady(bytes32)(bool)'", vm.toString(opId));
        console2.log("====================================");
    }

    function _printImmediateCall(address admin) internal view {
        bytes memory data = abi.encodeWithSignature("setCoverPoolImplementation(address)", _coverPoolImpl);
        console2.log("");
        console2.log("--- Immediate Multisig Call (CoverPool clone-target, CREATOR_ROLE) ---");
        console2.log("Execute AFTER executeBatch is confirmed. CREATOR_ROLE is on multisig directly.");
        console2.log("  From:", admin, " (multisig)");
        console2.log("  To:", _coverPoolFactoryProxy);
        console2.log("  Data:", vm.toString(data));
        console2.log("  Effect: new CoverPools get CYS3-01 USD-conversion fix.");
        console2.log("  Note: existing pool clones (EIP-1167) are unaffected.");
        console2.log("====================================");
    }
}
