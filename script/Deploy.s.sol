// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Upgrades, Options} from "@openzeppelin/upgrades/Upgrades.sol";
import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClaimManager} from "../src/ClaimManager.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPoolFactory} from "../src/CoverPoolFactory.sol";
import {Policy} from "../src/Policy.sol";
import {PolicyManager} from "../src/PolicyManager.sol";
import {PremiumManager} from "../src/PremiumManager.sol";
import {PremiumReserve} from "../src/PremiumReserve.sol";
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
 *        3. Policy proxy (soulbound ERC-721 for policy receipts)
 *        4. PremiumReserve proxy (escrow management for restaker premiums)
 *        5. PremiumManager proxy (premium collection and fee distribution)
 *        6. ClaimManager proxy (claim processing and payout orchestration)
 *        7. PolicyManager proxy (policy binding entrypoint)
 *        8. CoverPoolFactory proxy (pool creation and registry)
 *
 *      Phase 3 - Role configuration:
 *        - Grant actual roles to deployed contracts
 *        - Revoke temporary roles from deployer (when deployer != admin)
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key (defaults to Anvil key 0)
 *        - ADMIN: Admin address for all contracts (defaults to deployer)
 *        - SPEC_REGISTRY: SpecRegistry address (required)
 *        - SLASHING_MANAGER: Catalysis Core SlashingManager address (required)
 *        - STAKE_MANAGER: Catalysis Core StakeManager address (required)
 *        - REWARDS_MANAGER: Catalysis Core RewardsManager address (required)
 *        - CHAINLINK_PRICE_FEED: ChainlinkPriceFeed address (required)
 *        - PLATFORM_TREASURY: Platform fee recipient (defaults to admin)
 *        - PLATFORM_FEE_BPS: Platform fee in basis points (defaults to 500 = 5%)
 *        - COVER_POOL_FACTORY_CREATOR: Factory creator role (defaults to admin)
 *        - CLAIM_OPERATOR: Claim resolution operator (defaults to admin)
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
     * @param specRegistry SpecRegistry contract address.
     * @param slashingManager SlashingManager contract address from Catalysis Core.
     * @param chainlinkPriceFeed ChainlinkPriceFeed contract address from Catalysis Core.
     * @param stakeManager StakeManager contract address from Catalysis Core.
     * @param rewardsManager RewardsManager contract address from Catalysis Core.
     */
    struct ExternalConfig {
        address nativeWrapper;
        address specRegistry;
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
     * @param claimOperator CLAIM_OPERATOR_ROLE holder on ClaimManager.
     * @param swapManager SWAP_MANAGER_ROLE holder on Swapper.
     * @param platformTreasury Recipient address for platform fees.
     * @param platformFeeBps Platform fee in basis points.
     */
    struct RoleConfig {
        address deployer;
        address admin;
        address coverPoolFactoryCreator;
        address claimOperator;
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
     * @param policyProxy Policy UUPS proxy address.
     * @param policyImpl Policy implementation address.
     * @param premiumReserveProxy PremiumReserve UUPS proxy address.
     * @param premiumReserveImpl PremiumReserve implementation address.
     * @param premiumManagerProxy PremiumManager UUPS proxy address.
     * @param premiumManagerImpl PremiumManager implementation address.
     * @param claimManagerProxy ClaimManager UUPS proxy address.
     * @param claimManagerImpl ClaimManager implementation address.
     * @param policyManagerProxy PolicyManager UUPS proxy address.
     * @param policyManagerImpl PolicyManager implementation address.
     */
    struct DeployedContracts {
        address coverPoolImplementation;
        address coverPoolFactoryProxy;
        address coverPoolFactoryImpl;
        address swapperProxy;
        address swapperImpl;
        address policyProxy;
        address policyImpl;
        address premiumReserveProxy;
        address premiumReserveImpl;
        address premiumManagerProxy;
        address premiumManagerImpl;
        address claimManagerProxy;
        address claimManagerImpl;
        address policyManagerProxy;
        address policyManagerImpl;
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
            specRegistry: vm.envOr("SPEC_REGISTRY", address(0)),
            slashingManager: vm.envOr("SLASHING_MANAGER", address(0)),
            chainlinkPriceFeed: vm.envOr("CHAINLINK_PRICE_FEED", address(0)),
            stakeManager: vm.envOr("STAKE_MANAGER", address(0)),
            rewardsManager: vm.envOr("REWARDS_MANAGER", address(0))
        });
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

        _deployPolicyContracts(contracts, roles, opts);
        _deployPremiumContracts(contracts, roles, opts);
        _deployClaimAndFactoryContracts(contracts, roles, external_, opts);
    }

    /**
     * @notice Deploys the Policy soulbound ERC-721 contract.
     * @dev Policy stores canonical metadata for coverage policies. Uses deployer as temporary
     *      admin and POLICY_MANAGER_ROLE holder until PolicyManager is deployed.
     * @param contracts DeployedContracts struct to populate with Policy addresses.
     * @param roles Role configuration containing admin and deployer addresses.
     * @param opts Upgrade options to skip constructor validation for OZ 5.5 ReentrancyGuard.
     */
    function _deployPolicyContracts(
        DeployedContracts memory contracts,
        RoleConfig memory roles,
        Options memory opts
    )
        private
    {
        contracts.policyProxy = Upgrades.deployUUPSProxy(
            "Policy.sol:Policy", abi.encodeCall(Policy.initialize, (roles.deployer, roles.deployer)), opts
        );
        contracts.policyImpl = Upgrades.getImplementationAddress(contracts.policyProxy);
    }

    /**
     * @notice Deploys PremiumReserve and PremiumManager contracts.
     * @dev PremiumReserve holds restaker premiums in escrow; PremiumManager handles collection
     *      and fee distribution. Both use deployer as temporary admin and placeholder for manager roles.
     * @param contracts DeployedContracts struct to populate with premium contract addresses.
     * @param roles Role configuration containing admin, deployer, and platformTreasury addresses.
     * @param opts Upgrade options to skip constructor validation for OZ 5.5 ReentrancyGuard.
     */
    function _deployPremiumContracts(
        DeployedContracts memory contracts,
        RoleConfig memory roles,
        Options memory opts
    )
        private
    {
        contracts.premiumReserveProxy = Upgrades.deployUUPSProxy(
            "PremiumReserve.sol:PremiumReserve",
            abi.encodeCall(PremiumReserve.initialize, (roles.deployer, roles.deployer, roles.deployer, roles.deployer)),
            opts
        );
        contracts.premiumReserveImpl = Upgrades.getImplementationAddress(contracts.premiumReserveProxy);

        contracts.premiumManagerProxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol:PremiumManager",
            abi.encodeCall(
                PremiumManager.initialize,
                (roles.deployer, roles.deployer, contracts.premiumReserveProxy, roles.platformTreasury)
            ),
            opts
        );
        contracts.premiumManagerImpl = Upgrades.getImplementationAddress(contracts.premiumManagerProxy);
    }

    /**
     * @notice Deploys ClaimManager, PolicyManager, and CoverPoolFactory contracts.
     * @dev These contracts have dependencies on previously deployed contracts:
     *      - ClaimManager requires Swapper, Policy, and PremiumReserve
     *      - PolicyManager requires PremiumManager and Policy
     *      - CoverPoolFactory requires CoverPool implementation and PolicyManager
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
        contracts.claimManagerProxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol:ClaimManager",
            abi.encodeCall(
                ClaimManager.initialize,
                (
                    roles.deployer,
                    roles.claimOperator,
                    external_.specRegistry,
                    external_.slashingManager,
                    contracts.swapperProxy,
                    contracts.policyProxy,
                    contracts.premiumReserveProxy,
                    external_.chainlinkPriceFeed
                )
            ),
            opts
        );
        contracts.claimManagerImpl = Upgrades.getImplementationAddress(contracts.claimManagerProxy);

        contracts.policyManagerProxy = Upgrades.deployUUPSProxy(
            "PolicyManager.sol:PolicyManager",
            abi.encodeCall(
                PolicyManager.initialize,
                (roles.deployer, contracts.premiumManagerProxy, contracts.policyProxy, roles.platformFeeBps)
            ),
            opts
        );
        contracts.policyManagerImpl = Upgrades.getImplementationAddress(contracts.policyManagerProxy);

        contracts.coverPoolFactoryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (
                    roles.deployer,
                    roles.coverPoolFactoryCreator,
                    contracts.coverPoolImplementation,
                    contracts.policyManagerProxy,
                    external_.stakeManager
                )
            ),
            opts
        );
        contracts.coverPoolFactoryImpl = Upgrades.getImplementationAddress(contracts.coverPoolFactoryProxy);
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
     *      - Policy: POLICY_MANAGER_ROLE → PolicyManager (for minting policy NFTs)
     *      - PremiumReserve: PREMIUM_MANAGER_ROLE → PremiumManager (for opening escrows)
     *      - PremiumReserve: CLAIM_MANAGER_ROLE → ClaimManager (for claim lock/payout)
     *      - PremiumReserve: POLICY_MANAGER_ROLE → PolicyManager (for escrow release)
     *      - PremiumManager: POLICY_MANAGER_ROLE → PolicyManager (for premium collection)
     * @param contracts DeployedContracts containing all proxy addresses.
     * @param roles RoleConfig containing admin address for DEFAULT_ADMIN_ROLE grant.
     */
    function _grantRoles(DeployedContracts memory contracts, RoleConfig memory roles) private {
        bytes32 defaultAdminRole = bytes32(0);

        if (roles.deployer != roles.admin) {
            IAccessControl(contracts.swapperProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.policyProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.premiumReserveProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.premiumManagerProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.claimManagerProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.policyManagerProxy).grantRole(defaultAdminRole, roles.admin);
            IAccessControl(contracts.coverPoolFactoryProxy).grantRole(defaultAdminRole, roles.admin);
        }

        IAccessControl(contracts.swapperProxy)
            .grantRole(Swapper(payable(contracts.swapperProxy)).SWAP_EXECUTOR_ROLE(), contracts.claimManagerProxy);

        IAccessControl(contracts.policyProxy)
            .grantRole(Policy(contracts.policyProxy).POLICY_MANAGER_ROLE(), contracts.policyManagerProxy);

        IAccessControl(contracts.premiumReserveProxy)
            .grantRole(
                PremiumReserve(contracts.premiumReserveProxy).PREMIUM_MANAGER_ROLE(), contracts.premiumManagerProxy
            );
        IAccessControl(contracts.premiumReserveProxy)
            .grantRole(PremiumReserve(contracts.premiumReserveProxy).CLAIM_MANAGER_ROLE(), contracts.claimManagerProxy);
        IAccessControl(contracts.premiumReserveProxy)
            .grantRole(
                PremiumReserve(contracts.premiumReserveProxy).POLICY_MANAGER_ROLE(), contracts.policyManagerProxy
            );

        IAccessControl(contracts.premiumManagerProxy)
            .grantRole(
                PremiumManager(contracts.premiumManagerProxy).POLICY_MANAGER_ROLE(), contracts.policyManagerProxy
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

        IAccessControl(contracts.policyProxy)
            .revokeRole(Policy(contracts.policyProxy).POLICY_MANAGER_ROLE(), roles.deployer);

        IAccessControl(contracts.premiumReserveProxy)
            .revokeRole(PremiumReserve(contracts.premiumReserveProxy).PREMIUM_MANAGER_ROLE(), roles.deployer);
        IAccessControl(contracts.premiumReserveProxy)
            .revokeRole(PremiumReserve(contracts.premiumReserveProxy).CLAIM_MANAGER_ROLE(), roles.deployer);
        IAccessControl(contracts.premiumReserveProxy)
            .revokeRole(PremiumReserve(contracts.premiumReserveProxy).POLICY_MANAGER_ROLE(), roles.deployer);

        IAccessControl(contracts.premiumManagerProxy)
            .revokeRole(PremiumManager(contracts.premiumManagerProxy).POLICY_MANAGER_ROLE(), roles.deployer);

        // Note: Once revoked, deployer cannot manage roles on these contracts.
        IAccessControl(contracts.swapperProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.policyProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.premiumReserveProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.premiumManagerProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.claimManagerProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.policyManagerProxy).revokeRole(defaultAdminRole, roles.deployer);
        IAccessControl(contracts.coverPoolFactoryProxy).revokeRole(defaultAdminRole, roles.deployer);
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
        console2.log("SpecRegistry:", external_.specRegistry);
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
        console2.log("Policy Proxy:", contracts.policyProxy);
        console2.log("Policy Implementation:", contracts.policyImpl);
        console2.log("");
        console2.log("PremiumReserve Proxy:", contracts.premiumReserveProxy);
        console2.log("PremiumReserve Implementation:", contracts.premiumReserveImpl);
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
        roles.claimOperator = vm.envOr("CLAIM_OPERATOR", roles.admin);
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
        require(external_.specRegistry != address(0), "SPEC_REGISTRY required");
        require(external_.slashingManager != address(0), "SLASHING_MANAGER required");
        require(external_.chainlinkPriceFeed != address(0), "CHAINLINK_PRICE_FEED required");
        require(external_.stakeManager != address(0), "STAKE_MANAGER required");
        require(external_.rewardsManager != address(0), "REWARDS_MANAGER required");
    }
}
