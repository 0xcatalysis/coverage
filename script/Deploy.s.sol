// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ClaimManager} from "../src/ClaimManager.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPoolFactory} from "../src/CoverPoolFactory.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PremiumManager} from "../src/PremiumManager.sol";
import {SpecRegistry} from "../src/SpecRegistry.sol";
import {Swapper} from "../src/Swapper.sol";
import {CreateXDeployer} from "./CreateXDeployer.s.sol";

/**
 * @title Deploy
 * @notice Shared deployment helper that broadcasts all Catalysis Coverage contracts.
 * @dev Deployment follows a specific order to handle inter-contract dependencies:
 *
 *      Phase 0 - Governance:
 *        0. TimelockController (holds DEFAULT_ADMIN_ROLE on all contracts; multisig is proposer/executor)
 *
 *      Phase 1 - External-dependency-only contracts:
 *        1. CoverPool implementation (used by factory for minimal proxy clones)
 *        2. Swapper proxy (requires only WETH address)
 *
 *      Phase 2 - Contracts with circular dependencies (deployed with deployer as placeholder):
 *        3. PremiumManager proxy (premium distribution, fee splitting, and reward routing)
 *        4. ClaimManager proxy (claim processing and payout orchestration)
 *        5. PolicyManager proxy (policy binding entrypoint and policy storage)
 *        6. CoverPoolFactory proxy (pool creation and registry)
 *
 *      Phase 3 - Role configuration:
 *        - Grant DEFAULT_ADMIN_ROLE to TimelockController on all contracts
 *        - Grant operational roles (SWAP_EXECUTOR, CLAIM_MANAGER) directly to contracts
 *        - Revoke temporary roles from deployer
 *
 *      Environment Variables:
 *        - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag)
 *        - ADMIN: Admin address for all contracts (defaults to deployer)
 *        - NATIVE_WRAPPER: WETH or equivalent native token wrapper address (required)
 *        - SLASHING_MANAGER: Catalysis Core SlashingManager address (required)
 *        - STAKE_MANAGER: Catalysis Core StakeManager address (required)
 *        - REWARDS_MANAGER: Catalysis Core RewardsManager address (required)
 *        - CHAINLINK_PRICE_FEED: ChainlinkPriceFeed address (required)
 *        - PLATFORM_TREASURY: Platform fee recipient (defaults to admin)
 *        - PLATFORM_FEE_BPS: Platform fee in basis points (defaults to 500 = 5%)
 *        - COVER_POOL_FACTORY_CREATOR: Factory creator role (defaults to admin)
 *        - SWAP_MANAGER: Swap route configuration manager (defaults to admin)
 *        - TIMELOCK_MIN_DELAY: Minimum delay in seconds for TimelockController (defaults to 2 days)
 */
abstract contract Deploy is CreateXDeployer {
    /// @dev Default platform fee in basis points (5%).
    uint16 internal constant DEFAULT_PLATFORM_FEE_BPS = 500;

    /**
     * @notice Network-specific metadata used to validate deployments.
     * @param networkName Human-readable network label used in logs.
     * @param chainId Chain id required for the deployment run.
     */
    struct DeploymentConfig {
        string networkName;
        uint256 chainId;
    }

    /**
     * @notice External contract addresses required for deployment.
     * @param nativeWrapper WETH or equivalent native token wrapper address.
     * @param slashingManager SlashingManager contract address from Catalysis Core.
     * @param chainlinkPriceFeed ChainlinkPriceFeed contract address from Catalysis Core.
     * @param stakeManager StakeManager contract address from Catalysis Core.
     * @param rewardsManager RewardsManager contract address from Catalysis Core.
     */
    struct ExternalConfig {
        address nativeWrapper;
        address slashingManager;
        address chainlinkPriceFeed;
        address stakeManager;
        address rewardsManager;
    }

    /**
     * @notice Role configuration loaded from environment variables.
     * @param deployer Public address of the keystore signer, used for broadcasting.
     * @param admin DEFAULT_ADMIN_ROLE holder for all deployed contracts.
     * @param coverPoolFactoryCreator CREATOR_ROLE holder on CoverPoolFactory.
     * @param swapManager SWAP_MANAGER_ROLE holder on Swapper.
     * @param platformTreasury Recipient address for platform fees.
     * @param platformFeeBps Platform fee in basis points.
     * @param timelockMinDelay Minimum delay in seconds for TimelockController operations.
     */
    struct RoleConfig {
        address deployer;
        address admin;
        address coverPoolFactoryCreator;
        address swapManager;
        address platformTreasury;
        uint16 platformFeeBps;
        uint256 timelockMinDelay;
    }

    /**
     * @notice Collection of all deployed contract addresses.
     * @param timelockController TimelockController governance contract address.
     * @param coverPoolImplementation CoverPool implementation for minimal proxy clones.
     * @param coverPoolFactoryProxy CoverPoolFactory UUPS proxy address.
     * @param coverPoolFactoryImpl CoverPoolFactory implementation address.
     * @param swapperProxy Swapper UUPS proxy address.
     * @param swapperImpl Swapper implementation address.
     * @param premiumManagerProxy PremiumManager UUPS proxy address.
     * @param premiumManagerImpl PremiumManager implementation address.
     * @param claimManagerProxy ClaimManager UUPS proxy address.
     * @param claimManagerImpl ClaimManager implementation address.
     * @param policyManagerProxy PolicyManager UUPS proxy address.
     * @param policyManagerImpl PolicyManager implementation address.
     * @param specRegistryProxy SpecRegistry UUPS proxy address.
     * @param specRegistryImpl SpecRegistry implementation address.
     */
    struct DeployedContracts {
        address timelockController;
        address coverPoolImplementation;
        address coverPoolFactoryProxy;
        address coverPoolFactoryImpl;
        address swapperProxy;
        address swapperImpl;
        address premiumManagerProxy;
        address premiumManagerImpl;
        address claimManagerProxy;
        address claimManagerImpl;
        address policyManagerProxy;
        address policyManagerImpl;
        address specRegistryProxy;
        address specRegistryImpl;
    }

    /**
     * @notice Deploys all Catalysis Coverage contracts after validating chain id.
     * @dev Executes a three-phase deployment: contract deployment, role configuration, and logging.
     *      Reverts if the current chain id does not match the expected network configuration.
     * @return contracts Struct containing all deployed proxy and implementation addresses.
     */
    function run() external returns (DeployedContracts memory contracts) {
        DeploymentConfig memory config = getDeploymentConfig();
        require(config.chainId == block.chainid, string.concat("Must deploy on ", config.networkName));

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        RoleConfig memory roles = _loadRoleConfig(deployer);
        ExternalConfig memory external_ = _loadAndValidateExternalConfig();

        _ensureCreateX();

        vm.startBroadcast(deployer);

        contracts = _deployAllContracts(roles, external_);
        _configureRoles(contracts, roles);

        vm.stopBroadcast();

        _logDeployment(config, roles, external_, contracts);

        return contracts;
    }

    /**
     * @notice Provides the network name and expected chain id used for deployment validation.
     * @dev Must be overridden by network-specific deployment scripts (e.g., DeployAnvil, DeploySepolia).
     * @return DeploymentConfig containing network name and chain id.
     */
    function getDeploymentConfig() internal view virtual returns (DeploymentConfig memory);

    /**
     * @notice Provides external contract addresses required for deployment.
     * @dev Override in network-specific scripts to hardcode known addresses (e.g., WETH on mainnet).
     *      Falls back to environment variables when not overridden.
     * @return ExternalConfig containing nativeWrapper, specRegistry, slashingManager, stakeManager, and rewardsManager
     * addresses.
     */
    function getExternalConfig() internal view virtual returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: vm.envOr("NATIVE_WRAPPER", address(0)),
            slashingManager: vm.envOr("SLASHING_MANAGER", address(0)),
            chainlinkPriceFeed: vm.envOr("CHAINLINK_PRICE_FEED", address(0)),
            stakeManager: vm.envOr("STAKE_MANAGER", address(0)),
            rewardsManager: vm.envOr("REWARDS_MANAGER", address(0))
        });
    }

    /**
     * @notice Returns the minimum delay for the TimelockController in seconds.
     * @dev Defaults to 2 days (172800 seconds). Override in network-specific scripts
     *      (e.g. DeployAnvil returns 0 for instant local testing).
     *      Can also be set via the TIMELOCK_MIN_DELAY environment variable.
     * @return Minimum delay in seconds.
     */
    function getTimelockMinDelay() internal view virtual returns (uint256) {
        return vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));
    }

    /**
     * @notice Returns the initial payout tokens to whitelist on PolicyManager deployment.
     * @dev Reads comma-separated addresses from the PAYOUT_TOKENS environment variable.
     *      Returns an empty array if the variable is unset or empty.
     *      Override in network-specific scripts to provide tokens without environment variables.
     */
    function getInitialPayoutTokens() internal view virtual returns (address[] memory) {
        return _parseAddressList(vm.envOr("PAYOUT_TOKENS", string("")));
    }

    /**
     * @notice Returns the initial tokens to add to the PremiumManager approved token set.
     * @dev Reads comma-separated addresses from the PREMIUM_TOKENS environment variable.
     *      Returns an empty array if the variable is unset or empty.
     *      Only tokens in this set are accepted by distributePremium().
     *      Override in network-specific scripts to provide tokens without environment variables.
     */
    function getInitialPremiumTokens() internal view virtual returns (address[] memory) {
        return _parseAddressList(vm.envOr("PREMIUM_TOKENS", string("")));
    }

    /**
     * @notice Parses a comma-separated string of hex addresses into an address array.
     * @dev Splits on ',' and converts each segment to an address via vm.parseAddress.
     *      Skips empty segments produced by a missing or empty input string.
     * @param raw Comma-separated address string, e.g. "0xABC...,0xDEF...". Empty string returns [].
     * @return addrs Array of parsed addresses.
     */
    function _parseAddressList(string memory raw) private pure returns (address[] memory addrs) {
        bytes memory b = bytes(raw);
        if (b.length == 0) return new address[](0);

        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") ++count;
        }

        address[] memory temp = new address[](count);
        uint256 idx;
        uint256 start;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                if (i > start) {
                    bytes memory segment = new bytes(i - start);
                    for (uint256 j = start; j < i; j++) {
                        segment[j - start] = b[j];
                    }
                    temp[idx++] = vm.parseAddress(string(segment));
                }
                start = i + 1;
            }
        }

        addrs = new address[](idx);
        for (uint256 i = 0; i < idx; i++) {
            addrs[i] = temp[i];
        }
    }

    /**
     * @notice Precomputes all deterministic proxy addresses for a given deployer.
     * @dev Uses CREATE3 salt derivation — addresses are independent of bytecode or init args.
     *      Call off-chain (via forge script --sig) to know proxy addresses before deployment.
     * @param deployer Address that will broadcast the deployment transactions.
     * @return contracts Struct with proxy address fields populated (impl fields are zero).
     */
    function computeAllAddresses(address deployer) external pure returns (DeployedContracts memory contracts) {
        contracts.timelockController = _computeCreate3Address(deployer, "TimelockController");
        contracts.swapperProxy = _computeProxyAddress(deployer, "SwapperProxy");
        contracts.premiumManagerProxy = _computeProxyAddress(deployer, "PremiumManagerProxy");
        contracts.policyManagerProxy = _computeProxyAddress(deployer, "PolicyManagerProxy");
        contracts.specRegistryProxy = _computeProxyAddress(deployer, "SpecRegistryProxy");
        contracts.claimManagerProxy = _computeProxyAddress(deployer, "ClaimManagerProxy");
        contracts.coverPoolFactoryProxy = _computeProxyAddress(deployer, "CoverPoolFactoryProxy");
    }

    /**
     * @notice Orchestrates deployment of all contract proxies and implementations.
     * @dev Deploys contracts in dependency order. Uses deployer as temporary admin to enable
     *      role configuration phase. Final admin receives DEFAULT_ADMIN_ROLE in _grantRoles.
     * @param roles Role configuration containing admin, deployer, and other role addresses.
     * @param external_ External configuration containing Catalysis Core contract addresses.
     * @return contracts Populated DeployedContracts struct with all addresses.
     */
    function _deployAllContracts(
        RoleConfig memory roles,
        ExternalConfig memory external_
    )
        private
        returns (DeployedContracts memory contracts)
    {
        contracts.timelockController = _deployTimelockController(roles);
        contracts.coverPoolImplementation = address(new CoverPool());

        Swapper swapperImpl = new Swapper();
        contracts.swapperImpl = address(swapperImpl);
        contracts.swapperProxy = _deployProxy3(
            roles.deployer,
            "SwapperProxy",
            address(swapperImpl),
            abi.encodeCall(
                Swapper.initialize, (roles.deployer, roles.swapManager, roles.deployer, external_.nativeWrapper)
            )
        );

        _deployPremiumContracts(contracts, roles, external_);
        _deployClaimAndFactoryContracts(contracts, roles, external_);
    }

    /**
     * @notice Deploys an OZ TimelockController via CREATE3 for a deterministic address.
     * @dev The multisig (roles.admin) receives PROPOSER, EXECUTOR, and CANCELLER roles.
     *      The admin parameter is set to address(0), making the timelock self-administered only —
     *      delay changes must go through the timelock's own propose/execute flow.
     * @param roles Role configuration containing admin and deployer addresses.
     * @return The deployed TimelockController address.
     */
    function _deployTimelockController(RoleConfig memory roles) private returns (address) {
        address[] memory proposers = new address[](1);
        proposers[0] = roles.admin;
        address[] memory executors = new address[](1);
        executors[0] = roles.admin;

        bytes memory initCode = abi.encodePacked(
            type(TimelockController).creationCode, abi.encode(roles.timelockMinDelay, proposers, executors, address(0))
        );

        return _deploy3(roles.deployer, "TimelockController", initCode);
    }

    /**
     * @notice Deploys PremiumManager contract and approves initial premium tokens.
     * @dev PremiumManager handles premium distribution, fee splitting, and reward routing to RewardsManager.
     *      Uses deployer as temporary admin for role configuration.
     *      distributePremium() requires the token to be in the approved set — see getInitialPremiumTokens().
     * @param contracts DeployedContracts struct to populate with premium contract addresses.
     * @param roles Role configuration containing admin, deployer, and platformTreasury addresses.
     * @param external_ External configuration containing RewardsManager address.
     */
    function _deployPremiumContracts(
        DeployedContracts memory contracts,
        RoleConfig memory roles,
        ExternalConfig memory external_
    )
        private
    {
        PremiumManager premiumManagerImpl = new PremiumManager();
        contracts.premiumManagerImpl = address(premiumManagerImpl);
        contracts.premiumManagerProxy = _deployProxy3(
            roles.deployer,
            "PremiumManagerProxy",
            address(premiumManagerImpl),
            abi.encodeCall(
                PremiumManager.initialize,
                (roles.deployer, external_.rewardsManager, roles.platformTreasury, roles.platformFeeBps)
            )
        );

        address[] memory premiumTokens = getInitialPremiumTokens();
        for (uint256 i = 0; i < premiumTokens.length; i++) {
            PremiumManager(contracts.premiumManagerProxy).addApprovedPremiumToken(premiumTokens[i]);
        }
    }

    /**
     * @notice Deploys ClaimManager, PolicyManager, and CoverPoolFactory contracts.
     * @dev These contracts have dependencies on previously deployed contracts:
     *      - ClaimManager requires Swapper and PolicyManager
     *      - PolicyManager requires PremiumManager and stores policy metadata
     *      - CoverPoolFactory requires CoverPool implementation and PolicyManager
     *      All use deployer as temporary admin for role configuration phase.
     * @param contracts DeployedContracts struct to populate with remaining contract addresses.
     * @param roles Role configuration containing admin and role holder addresses.
     * @param external_ External configuration containing Catalysis Core addresses.
     */
    function _deployClaimAndFactoryContracts(
        DeployedContracts memory contracts,
        RoleConfig memory roles,
        ExternalConfig memory external_
    )
        private
    {
        PolicyManager policyManagerImpl = new PolicyManager();
        contracts.policyManagerImpl = address(policyManagerImpl);
        contracts.policyManagerProxy = _deployProxy3(
            roles.deployer,
            "PolicyManagerProxy",
            address(policyManagerImpl),
            abi.encodeCall(
                PolicyManager.initialize,
                (
                    roles.deployer,
                    external_.stakeManager,
                    roles.deployer, // Temporary placeholder for claimManager, will be set after ClaimManager deployment
                    roles.deployer, // Temporary placeholder for coverPoolFactory, will be set after factory deployment
                    external_.chainlinkPriceFeed,
                    getInitialPayoutTokens()
                )
            )
        );

        SpecRegistry specRegistryImpl = new SpecRegistry();
        contracts.specRegistryImpl = address(specRegistryImpl);
        contracts.specRegistryProxy = _deployProxy3(
            roles.deployer,
            "SpecRegistryProxy",
            address(specRegistryImpl),
            abi.encodeCall(SpecRegistry.initialize, (roles.deployer, address(0)))
        );

        ClaimManager claimManagerImpl = new ClaimManager();
        contracts.claimManagerImpl = address(claimManagerImpl);
        contracts.claimManagerProxy = _deployProxy3(
            roles.deployer,
            "ClaimManagerProxy",
            address(claimManagerImpl),
            abi.encodeCall(
                ClaimManager.initialize,
                (
                    roles.deployer,
                    contracts.specRegistryProxy,
                    external_.slashingManager,
                    contracts.swapperProxy,
                    contracts.policyManagerProxy
                )
            )
        );

        ClaimManager(payable(contracts.claimManagerProxy)).setPremiumManager(contracts.premiumManagerProxy);
        ClaimManager(payable(contracts.claimManagerProxy)).initializeV2(external_.chainlinkPriceFeed, 300);

        PolicyManager(contracts.policyManagerProxy).setClaimManager(contracts.claimManagerProxy);

        CoverPoolFactory coverPoolFactoryImpl = new CoverPoolFactory();
        contracts.coverPoolFactoryImpl = address(coverPoolFactoryImpl);
        contracts.coverPoolFactoryProxy = _deployProxy3(
            roles.deployer,
            "CoverPoolFactoryProxy",
            address(coverPoolFactoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (
                    roles.deployer,
                    roles.coverPoolFactoryCreator,
                    contracts.coverPoolImplementation,
                    contracts.policyManagerProxy,
                    external_.stakeManager,
                    contracts.specRegistryProxy
                )
            )
        );

        PolicyManager(contracts.policyManagerProxy).setCoverPoolFactory(contracts.coverPoolFactoryProxy);
        SpecRegistry(contracts.specRegistryProxy).setCoverPoolFactory(contracts.coverPoolFactoryProxy);
    }

    /**
     * @notice Configures cross-contract roles after all contracts are deployed.
     * @dev Grants actual roles to deployed contracts (including DEFAULT_ADMIN_ROLE to final admin)
     *      and revokes temporary roles from deployer. This two-step process is necessary because
     *      some contracts require role holders to exist at initialization time, creating circular
     *      dependencies.
     * @param contracts DeployedContracts containing all proxy addresses for role assignment.
     * @param roles RoleConfig containing deployer address for temporary role revocation.
     */
    function _configureRoles(DeployedContracts memory contracts, RoleConfig memory roles) private {
        _grantRoles(contracts);
        _revokeTemporaryRoles(contracts, roles);
    }

    /**
     * @notice Grants permanent roles to deployed contracts enabling cross-contract interactions.
     * @dev Role assignments:
     *      - All contracts: DEFAULT_ADMIN_ROLE → TimelockController (governance layer)
     *      - Swapper: SWAP_EXECUTOR_ROLE → ClaimManager (for collateral conversion)
     *      - PremiumManager: CLAIM_MANAGER_ROLE → ClaimManager (for surplus distribution)
     *
     *      The multisig interacts with contracts via the TimelockController's
     *      schedule/execute flow. Operational roles (SWAP_EXECUTOR, CLAIM_MANAGER) are granted
     *      directly to contracts for automated cross-contract calls.
     *
     *      NOTE: distributePremium() on PremiumManager is permissionless but requires the token
     *      to be in the approved set. Initial tokens are added in _deployPremiumContracts().
     * @param contracts DeployedContracts containing all proxy addresses.
     */
    function _grantRoles(DeployedContracts memory contracts) private {
        bytes32 defaultAdminRole = bytes32(0);
        address tc = contracts.timelockController;

        // Grant DEFAULT_ADMIN_ROLE to TimelockController on all contracts
        IAccessControl(contracts.swapperProxy).grantRole(defaultAdminRole, tc);
        IAccessControl(contracts.premiumManagerProxy).grantRole(defaultAdminRole, tc);
        IAccessControl(contracts.claimManagerProxy).grantRole(defaultAdminRole, tc);
        IAccessControl(contracts.policyManagerProxy).grantRole(defaultAdminRole, tc);
        IAccessControl(contracts.coverPoolFactoryProxy).grantRole(defaultAdminRole, tc);
        IAccessControl(contracts.specRegistryProxy).grantRole(defaultAdminRole, tc);

        // Operational roles — direct contract-to-contract, not through timelock
        IAccessControl(contracts.swapperProxy)
            .grantRole(Swapper(payable(contracts.swapperProxy)).SWAP_EXECUTOR_ROLE(), contracts.claimManagerProxy);

        IAccessControl(contracts.premiumManagerProxy)
            .grantRole(PremiumManager(contracts.premiumManagerProxy).CLAIM_MANAGER_ROLE(), contracts.claimManagerProxy);
    }

    /**
     * @notice Revokes temporary roles from deployer (and admin if separate) after TimelockController is wired.
     * @dev The TimelockController now holds DEFAULT_ADMIN_ROLE on all contracts, so both the deployer
     *      and the admin (multisig) must have their direct roles revoked. The deployer's
     *      SWAP_EXECUTOR_ROLE placeholder is also revoked (ClaimManager now holds it).
     *      DEFAULT_ADMIN_ROLE is revoked last to ensure all other revocations succeed.
     * @param contracts DeployedContracts containing all proxy addresses.
     * @param roles RoleConfig containing deployer and admin addresses.
     */
    function _revokeTemporaryRoles(DeployedContracts memory contracts, RoleConfig memory roles) private {
        bytes32 defaultAdminRole = bytes32(0);

        // Revoke deployer's placeholder SWAP_EXECUTOR_ROLE (ClaimManager now holds it)
        IAccessControl(contracts.swapperProxy)
            .revokeRole(Swapper(payable(contracts.swapperProxy)).SWAP_EXECUTOR_ROLE(), roles.deployer);

        // Revoke deployer's DEFAULT_ADMIN_ROLE from all contracts
        IAccessControl(contracts.swapperProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.premiumManagerProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.claimManagerProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.policyManagerProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.coverPoolFactoryProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.specRegistryProxy).revokeRole(defaultAdminRole, roles.deployer);
    }

    /**
     * @notice Logs all deployment information to console for verification and record-keeping.
     * @dev Outputs network info, account addresses, external dependencies, and all deployed
     *      contract addresses (both proxies and implementations) in a structured format.
     * @param config Network configuration with name and chain id.
     * @param roles Role configuration with deployer, admin, and treasury addresses.
     * @param external_ External configuration with Catalysis Core addresses.
     * @param contracts All deployed contract addresses.
     */
    function _logDeployment(
        DeploymentConfig memory config,
        RoleConfig memory roles,
        ExternalConfig memory external_,
        DeployedContracts memory contracts
    )
        private
        pure
    {
        console2.log("");
        console2.log(string.concat("=== ", config.networkName, " Deployment ==="));
        console2.log("Chain ID:", config.chainId);
        console2.log("");

        console2.log("--- Accounts ---");
        console2.log("Deployer:", roles.deployer);
        console2.log("Admin:", roles.admin);
        console2.log("Platform Treasury:", roles.platformTreasury);
        console2.log("");

        console2.log("--- Governance ---");
        console2.log("TimelockController:", contracts.timelockController);
        console2.log("Timelock Min Delay:", roles.timelockMinDelay, "seconds");
        console2.log("");

        console2.log("--- External Dependencies ---");
        console2.log("Native Wrapper (WETH):", external_.nativeWrapper);
        console2.log("SlashingManager:", external_.slashingManager);
        console2.log("StakeManager:", external_.stakeManager);
        console2.log("RewardsManager:", external_.rewardsManager);
        console2.log("");

        console2.log("--- Deployed Contracts ---");
        console2.log("CoverPool Implementation:", contracts.coverPoolImplementation);
        console2.log("");
        console2.log("Swapper Proxy:", contracts.swapperProxy);
        console2.log("Swapper Implementation:", contracts.swapperImpl);
        console2.log("");
        console2.log("PremiumManager Proxy:", contracts.premiumManagerProxy);
        console2.log("PremiumManager Implementation:", contracts.premiumManagerImpl);
        console2.log("");
        console2.log("ClaimManager Proxy:", contracts.claimManagerProxy);
        console2.log("ClaimManager Implementation:", contracts.claimManagerImpl);
        console2.log("");
        console2.log("PolicyManager Proxy:", contracts.policyManagerProxy);
        console2.log("PolicyManager Implementation:", contracts.policyManagerImpl);
        console2.log("");
        console2.log("CoverPoolFactory Proxy:", contracts.coverPoolFactoryProxy);
        console2.log("CoverPoolFactory Implementation:", contracts.coverPoolFactoryImpl);
        console2.log("");
        console2.log("SpecRegistry Proxy:", contracts.specRegistryProxy);
        console2.log("SpecRegistry Implementation:", contracts.specRegistryImpl);
        console2.log("====================================");
    }

    /**
     * @notice Loads role configuration from environment variables with sensible defaults.
     * @dev Derives deployer from private key; admin defaults to deployer; all other roles default to admin.
     * @param deployer Deployer address loaded from DEPLOYER_ADDRESS env var.
     * @return roles Populated RoleConfig struct.
     */
    function _loadRoleConfig(address deployer) private view returns (RoleConfig memory roles) {
        roles.deployer = deployer;
        roles.admin = vm.envOr("ADMIN", roles.deployer);
        roles.coverPoolFactoryCreator = vm.envOr("COVER_POOL_FACTORY_CREATOR", roles.admin);
        roles.swapManager = vm.envOr("SWAP_MANAGER", roles.admin);
        roles.platformTreasury = vm.envOr("PLATFORM_TREASURY", roles.admin);
        roles.platformFeeBps = uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(DEFAULT_PLATFORM_FEE_BPS)));
        roles.timelockMinDelay = getTimelockMinDelay();
    }

    /**
     * @notice Loads external configuration and validates all required addresses are non-zero.
     * @dev Reverts with descriptive message if any required external address is missing.
     * @return external_ Validated ExternalConfig struct.
     */
    function _loadAndValidateExternalConfig() private view returns (ExternalConfig memory external_) {
        external_ = getExternalConfig();
        require(external_.nativeWrapper != address(0), "Native wrapper address required");
        require(external_.slashingManager != address(0), "SLASHING_MANAGER required");
        require(external_.chainlinkPriceFeed != address(0), "CHAINLINK_PRICE_FEED required");
        require(external_.stakeManager != address(0), "STAKE_MANAGER required");
        require(external_.rewardsManager != address(0), "REWARDS_MANAGER required");
    }
}
