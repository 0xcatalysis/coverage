// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Upgrades, Options} from "@openzeppelin/upgrades/Upgrades.sol";
import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClaimManager} from "../src/ClaimManager.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPoolFactory} from "../src/CoverPoolFactory.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PremiumCollector} from "../src/PremiumCollector.sol";
import {PremiumManager} from "../src/PremiumManager.sol";
import {SpecRegistry} from "../src/SpecRegistry.sol";
import {Swapper} from "../src/Swapper.sol";

/**
 * @title Deploy
 * @notice Shared deployment helper that broadcasts all Catalysis Coverage contracts.
 * @dev Deployment follows a specific order to handle inter-contract dependencies:
 *
 *      Phase 1 - External-dependency-only contracts:
 *        1. CoverPool implementation (used by factory for minimal proxy clones)
 *        2. Swapper proxy (requires only WETH address)
 *
 *      Phase 2 - Contracts with circular dependencies (deployed with deployer as placeholder):
 *        3. PremiumManager proxy (premium distribution, fee splitting, and reward routing)
 *        4. PremiumCollector proxy (ERC-4626 vault share accrual and periodic redemption)
 *        5. ClaimManager proxy (claim processing and payout orchestration)
 *        6. PolicyManager proxy (policy binding entrypoint and policy storage)
 *        7. CoverPoolFactory proxy (pool creation and registry)
 *
 *      Phase 3 - Role configuration:
 *        - Grant actual roles to deployed contracts
 *        - Revoke temporary roles from deployer (when deployer != admin)
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key (defaults to Anvil key 0)
 *        - ADMIN: Admin address for all contracts (defaults to deployer)
 *        - SLASHING_MANAGER: Catalysis Core SlashingManager address (required)
 *        - STAKE_MANAGER: Catalysis Core StakeManager address (required)
 *        - REWARDS_MANAGER: Catalysis Core RewardsManager address (required)
 *        - CHAINLINK_PRICE_FEED: ChainlinkPriceFeed address (required)
 *        - PLATFORM_TREASURY: Platform fee recipient (defaults to admin)
 *        - PLATFORM_FEE_BPS: Platform fee in basis points (defaults to 500 = 5%)
 *        - COVER_POOL_FACTORY_CREATOR: Factory creator role (defaults to admin)
 *        - SWAP_MANAGER: Swap route configuration manager (defaults to admin)
 */
abstract contract Deploy is Script {
    /// @dev Default Anvil private key for local testing.
    uint256 internal constant DEFAULT_PRIVATE_KEY =
        uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);

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
     * @param deployer Address derived from PRIVATE_KEY, used for broadcasting.
     * @param admin DEFAULT_ADMIN_ROLE holder for all deployed contracts.
     * @param coverPoolFactoryCreator CREATOR_ROLE holder on CoverPoolFactory.
     * @param swapManager SWAP_MANAGER_ROLE holder on Swapper.
     * @param platformTreasury Recipient address for platform fees.
     * @param platformFeeBps Platform fee in basis points.
     */
    struct RoleConfig {
        address deployer;
        address admin;
        address coverPoolFactoryCreator;
        address swapManager;
        address platformTreasury;
        uint16 platformFeeBps;
    }

    /**
     * @notice Collection of all deployed contract addresses.
     * @param coverPoolImplementation CoverPool implementation for minimal proxy clones.
     * @param coverPoolFactoryProxy CoverPoolFactory UUPS proxy address.
     * @param coverPoolFactoryImpl CoverPoolFactory implementation address.
     * @param swapperProxy Swapper UUPS proxy address.
     * @param swapperImpl Swapper implementation address.
     * @param premiumCollectorProxy PremiumCollector UUPS proxy address.
     * @param premiumCollectorImpl PremiumCollector implementation address.
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
        address coverPoolImplementation;
        address coverPoolFactoryProxy;
        address coverPoolFactoryImpl;
        address swapperProxy;
        address swapperImpl;
        address premiumCollectorProxy;
        address premiumCollectorImpl;
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

        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        RoleConfig memory roles = _loadRoleConfig(deployerPrivateKey);
        ExternalConfig memory external_ = _loadAndValidateExternalConfig();

        vm.startBroadcast(deployerPrivateKey);

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
     * @notice Returns the initial payout tokens to whitelist on PolicyManager deployment.
     * @dev Override in network-specific scripts (e.g. DeploySepolia) to return USDC or other tokens.
     *      Default returns empty array.
     */
    function getInitialPayoutTokens() internal view virtual returns (address[] memory) {
        return new address[](0);
    }

    /**
     * @notice Orchestrates deployment of all contract proxies and implementations.
     * @dev Deploys contracts in dependency order. Uses deployer as temporary admin to enable
     *      role configuration phase. Final admin receives DEFAULT_ADMIN_ROLE in _grantRoles.
     *
     *      PolicyManager is deployed before PremiumManager so its address can be passed directly
     *      into PremiumManager.initialize, avoiding a two-step address(0) + setPolicyManager pattern.
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
        // OZ 5.5 uses base ReentrancyGuard (not Upgradeable variant) with namespaced storage.
        // The constructor is safe for proxies but the validation tool still flags it.
        Options memory opts;
        opts.unsafeAllow = "constructor";

        contracts.coverPoolImplementation = address(new CoverPool());

        contracts.swapperProxy = Upgrades.deployUUPSProxy(
            "Swapper.sol:Swapper",
            abi.encodeCall(
                Swapper.initialize, (roles.deployer, roles.swapManager, roles.deployer, external_.nativeWrapper)
            ),
            opts
        );
        contracts.swapperImpl = Upgrades.getImplementationAddress(contracts.swapperProxy);

        contracts.policyManagerProxy = Upgrades.deployUUPSProxy(
            "PolicyManager.sol:PolicyManager",
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
            ),
            opts
        );
        contracts.policyManagerImpl = Upgrades.getImplementationAddress(contracts.policyManagerProxy);

        _deployPremiumContracts(contracts, roles, external_, opts);
        _deployClaimAndFactoryContracts(contracts, roles, external_, opts);
    }

    /**
     * @notice Deploys PremiumManager and PremiumCollector contracts.
     * @dev PremiumManager handles premium distribution, fee splitting, and reward routing to RewardsManager.
     *      PremiumCollector is deployed later, after CoverPoolFactory exists, so it can be initialized
     *      with a valid factory address and avoid placeholder wiring.
     *      PolicyManager must be deployed before this function is called so its address can be passed
     *      directly into PremiumManager.initialize.
     *      Uses deployer as temporary admin for role configuration.
     * @param contracts DeployedContracts struct to populate with premium contract addresses.
     * @param roles Role configuration containing admin, deployer, and platformTreasury addresses.
     * @param external_ External configuration containing RewardsManager address.
     * @param opts Upgrade options to skip constructor validation for OZ 5.5 ReentrancyGuard.
     */
    function _deployPremiumContracts(
        DeployedContracts memory contracts,
        RoleConfig memory roles,
        ExternalConfig memory external_,
        Options memory opts
    )
        private
    {
        contracts.premiumManagerProxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol:PremiumManager",
            abi.encodeCall(
                PremiumManager.initialize,
                (
                    roles.deployer,
                    external_.rewardsManager,
                    roles.platformTreasury,
                    roles.platformFeeBps,
                    contracts.policyManagerProxy
                )
            ),
            opts
        );
        contracts.premiumManagerImpl = Upgrades.getImplementationAddress(contracts.premiumManagerProxy);
    }

    /**
     * @notice Deploys ClaimManager, SpecRegistry, CoverPoolFactory, and PremiumCollector contracts.
     * @dev These contracts have dependencies on previously deployed contracts:
     *      - ClaimManager requires Swapper and PolicyManager
     *      - CoverPoolFactory requires CoverPool implementation and PolicyManager
     *      - PremiumCollector requires PremiumManager and CoverPoolFactory
     *      PolicyManager is deployed earlier in _deployAllContracts so its address is available to
     *      both PremiumManager.initialize and this function.
     *      All use deployer as temporary admin for role configuration phase.
     * @param contracts DeployedContracts struct to populate with remaining contract addresses.
     * @param roles Role configuration containing admin and role holder addresses.
     * @param external_ External configuration containing Catalysis Core addresses.
     * @param opts Upgrade options to skip constructor validation for OZ 5.5 ReentrancyGuard.
     */
    function _deployClaimAndFactoryContracts(
        DeployedContracts memory contracts,
        RoleConfig memory roles,
        ExternalConfig memory external_,
        Options memory opts
    )
        private
    {
        contracts.specRegistryProxy = Upgrades.deployUUPSProxy(
            "SpecRegistry.sol:SpecRegistry", abi.encodeCall(SpecRegistry.initialize, (roles.deployer, address(0))), opts
        );
        contracts.specRegistryImpl = Upgrades.getImplementationAddress(contracts.specRegistryProxy);

        contracts.claimManagerProxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol:ClaimManager",
            abi.encodeCall(
                ClaimManager.initialize,
                (
                    roles.deployer,
                    contracts.specRegistryProxy,
                    external_.slashingManager,
                    contracts.swapperProxy,
                    contracts.policyManagerProxy
                )
            ),
            opts
        );
        contracts.claimManagerImpl = Upgrades.getImplementationAddress(contracts.claimManagerProxy);

        PolicyManager(contracts.policyManagerProxy).setClaimManager(contracts.claimManagerProxy);

        contracts.coverPoolFactoryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
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
            ),
            opts
        );
        contracts.coverPoolFactoryImpl = Upgrades.getImplementationAddress(contracts.coverPoolFactoryProxy);

        PolicyManager(contracts.policyManagerProxy).setCoverPoolFactory(contracts.coverPoolFactoryProxy);
        PolicyManager(contracts.policyManagerProxy).setChainlinkPriceFeed(external_.chainlinkPriceFeed);
        SpecRegistry(contracts.specRegistryProxy).setCoverPoolFactory(contracts.coverPoolFactoryProxy);

        uint64 distributeInterval = 86_400; // 24 hours
        contracts.premiumCollectorProxy = Upgrades.deployUUPSProxy(
            "PremiumCollector.sol:PremiumCollector",
            abi.encodeCall(
                PremiumCollector.initialize,
                (roles.deployer, contracts.premiumManagerProxy, contracts.coverPoolFactoryProxy, distributeInterval)
            ),
            opts
        );
        contracts.premiumCollectorImpl = Upgrades.getImplementationAddress(contracts.premiumCollectorProxy);
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
        _grantRoles(contracts, roles);
        _revokeTemporaryRoles(contracts, roles);
    }

    /**
     * @notice Grants permanent roles to deployed contracts enabling cross-contract interactions.
     * @dev Role assignments:
     *      - All contracts: DEFAULT_ADMIN_ROLE → roles.admin (when deployer != admin)
     *      - Swapper: SWAP_EXECUTOR_ROLE → ClaimManager (for collateral conversion)
     *      - PremiumManager: PREMIUM_COLLECTOR_ROLE → PremiumCollector (for premium distribution)
     * @param contracts DeployedContracts containing all proxy addresses.
     * @param roles RoleConfig containing admin address for DEFAULT_ADMIN_ROLE grant.
     */
    function _grantRoles(DeployedContracts memory contracts, RoleConfig memory roles) private {
        bytes32 defaultAdminRole = bytes32(0);

        if (roles.deployer != roles.admin) {
            IAccessControl(contracts.swapperProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.premiumCollectorProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.premiumManagerProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.claimManagerProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.policyManagerProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.coverPoolFactoryProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.specRegistryProxy).grantRole(defaultAdminRole, roles.admin);
        }

        IAccessControl(contracts.swapperProxy)
            .grantRole(Swapper(payable(contracts.swapperProxy)).SWAP_EXECUTOR_ROLE(), contracts.claimManagerProxy);

        IAccessControl(contracts.premiumManagerProxy)
            .grantRole(
                PremiumManager(contracts.premiumManagerProxy).PREMIUM_COLLECTOR_ROLE(), contracts.premiumCollectorProxy
            );
    }

    /**
     * @notice Revokes temporary roles from deployer when deployer differs from admin.
     * @dev Skips revocation when deployer == admin to avoid breaking admin's ability to manage roles.
     *      In production deployments where deployer != admin, this ensures the deployer EOA
     *      cannot interact with privileged contract functions after deployment.
     *      DEFAULT_ADMIN_ROLE is revoked last to ensure all other revocations succeed.
     * @param contracts DeployedContracts containing all proxy addresses.
     * @param roles RoleConfig containing deployer and admin addresses.
     */
    function _revokeTemporaryRoles(DeployedContracts memory contracts, RoleConfig memory roles) private {
        if (roles.deployer == roles.admin) {
            return;
        }

        bytes32 defaultAdminRole = bytes32(0);

        IAccessControl(contracts.swapperProxy)
            .revokeRole(Swapper(payable(contracts.swapperProxy)).SWAP_EXECUTOR_ROLE(), roles.deployer);

        IAccessControl(contracts.swapperProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.premiumCollectorProxy).revokeRole(defaultAdminRole, roles.deployer);
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

        console2.log("--- External Dependencies ---");
        console2.log("Native Wrapper (WETH):", external_.nativeWrapper);
        console2.log("SlashingManager:", external_.slashingManager);
        console2.log("ChainlinkPriceFeed:", external_.chainlinkPriceFeed);
        console2.log("StakeManager:", external_.stakeManager);
        console2.log("RewardsManager:", external_.rewardsManager);
        console2.log("");

        console2.log("--- Deployed Contracts ---");
        console2.log("CoverPool Implementation:", contracts.coverPoolImplementation);
        console2.log("");
        console2.log("Swapper Proxy:", contracts.swapperProxy);
        console2.log("Swapper Implementation:", contracts.swapperImpl);
        console2.log("");
        console2.log("PremiumCollector Proxy:", contracts.premiumCollectorProxy);
        console2.log("PremiumCollector Implementation:", contracts.premiumCollectorImpl);
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
     * @param deployerPrivateKey Private key used to derive the deployer address.
     * @return roles Populated RoleConfig struct.
     */
    function _loadRoleConfig(uint256 deployerPrivateKey) private view returns (RoleConfig memory roles) {
        roles.deployer = vm.addr(deployerPrivateKey);
        roles.admin = vm.envOr("ADMIN", roles.deployer);
        roles.coverPoolFactoryCreator = vm.envOr("COVER_POOL_FACTORY_CREATOR", roles.admin);
        roles.swapManager = vm.envOr("SWAP_MANAGER", roles.admin);
        roles.platformTreasury = vm.envOr("PLATFORM_TREASURY", roles.admin);
        roles.platformFeeBps = uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(DEFAULT_PLATFORM_FEE_BPS)));
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
