// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Paginator} from "@solarity/contracts/libs/arrays/Paginator.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";
import {ICoverPoolRegistry} from "./interfaces/ICoverPoolRegistry.sol";

/**
 * @title CoverPoolFactory
 * @notice Deploys CoverPool minimal clones and maintains registry metadata for created pools.
 * @dev Combines the previous factory and registry responsibilities into a single upgradeable contract.
 */
contract CoverPoolFactory is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ICoverPoolFactory
{
    using Clones for address;

    bytes32 public constant override CREATOR_ROLE = keccak256("CREATOR_ROLE");

    uint16 private constant _MAX_FEE_BPS = 2000;

    address public override coverPoolImplementation;
    address public override policyManager;

    mapping(address pool => PoolConfig) private _poolConfigs;
    address[] private _pools;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes factory configuration and admin role.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param creator_ Address receiving CREATOR_ROLE.
     * @param coverPoolImplementation_ Address of the CoverPool implementation contract.
     * @param policyManager_ Address of the PolicyManager contract.
     */
    function initialize(
        address admin_,
        address creator_,
        address coverPoolImplementation_,
        address policyManager_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && creator_ != address(0) && coverPoolImplementation_ != address(0)
                && policyManager_ != address(0),
            ZeroAddress()
        );
        require(coverPoolImplementation_.code.length != 0, InvalidImplementation());

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CREATOR_ROLE, creator_);

        coverPoolImplementation = coverPoolImplementation_;
        policyManager = policyManager_;
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function createCoverPool(CreateCoverPoolParams calldata params)
        external
        override
        nonReentrant
        onlyRole(CREATOR_ROLE)
        whenNotPaused
    {
        require(params.quoteSigner != address(0), ZeroAddress());

        address coverPool = coverPoolImplementation.clone();

        PoolConfig memory config = PoolConfig({
            pool: coverPool,
            curator: params.curator,
            premiumToken: params.premiumToken,
            payoutToken: params.payoutToken,
            defaultSpecId: params.defaultSpecId,
            poolFeeBps: params.poolFeeBps,
            platformFeeBps: params.platformFeeBps,
            active: params.active
        });
        _validateConfig(config);

        _poolConfigs[coverPool] = config;
        _pools.push(coverPool);

        address policyManager_ = policyManager;
        ICoverPool(coverPool).initialize(params.curator, policyManager_, params.quoteSigner);

        emit CoverPoolCreated(coverPool, params.curator, params.quoteSigner, policyManager_);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setCoverPoolImplementation(address newImplementation) external override onlyRole(CREATOR_ROLE) {
        require(newImplementation != address(0), ZeroAddress());
        require(newImplementation.code.length != 0, InvalidImplementation());

        address previousImplementation = coverPoolImplementation;
        coverPoolImplementation = newImplementation;

        emit CoverPoolImplementationSet(previousImplementation, newImplementation);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setPolicyManager(address newPolicyManager) external override onlyRole(CREATOR_ROLE) {
        require(newPolicyManager != address(0), ZeroAddress());

        address previousPolicyManager = policyManager;
        policyManager = newPolicyManager;

        emit PolicyManagerSet(previousPolicyManager, newPolicyManager);
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function updatePoolConfig(
        address pool,
        PoolConfig calldata newConfig
    )
        external
        override
        onlyRole(CREATOR_ROLE)
        whenNotPaused
    {
        require(_poolConfigs[pool].pool != address(0), PoolNotRegistered(pool));

        PoolConfig memory updated = PoolConfig({
            pool: pool,
            curator: newConfig.curator,
            premiumToken: newConfig.premiumToken,
            payoutToken: newConfig.payoutToken,
            defaultSpecId: newConfig.defaultSpecId,
            poolFeeBps: newConfig.poolFeeBps,
            platformFeeBps: newConfig.platformFeeBps,
            active: newConfig.active
        });
        _validateConfig(updated);

        PoolConfig storage config = _poolConfigs[pool];
        require(config.active == updated.active, PoolActiveStatusMismatch());

        config.curator = updated.curator;
        config.premiumToken = updated.premiumToken;
        config.payoutToken = updated.payoutToken;
        config.defaultSpecId = updated.defaultSpecId;
        config.poolFeeBps = updated.poolFeeBps;
        config.platformFeeBps = updated.platformFeeBps;

        emit PoolConfigUpdated(pool, config);
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function setPoolStatus(address pool, bool active) external override onlyRole(CREATOR_ROLE) {
        PoolConfig storage config = _poolConfigs[pool];
        require(config.pool != address(0), PoolNotRegistered(pool));
        require(config.active != active, PoolStatusUnchanged());

        config.active = active;

        emit PoolStatusSet(pool, active);
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function listPools(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (address[] memory pools, PoolConfig[] memory configs)
    {
        require(limit != 0, InvalidLimit());

        uint256 totalPools = _pools.length;
        if (totalPools == 0 || offset >= totalPools) {
            return (new address[](0), new PoolConfig[](0));
        }

        uint256 to = Paginator.getTo(totalPools, offset, limit);
        uint256 length = to - offset;
        if (length == 0) {
            return (new address[](0), new PoolConfig[](0));
        }

        pools = new address[](length);
        configs = new PoolConfig[](length);

        for (uint256 i = 0; i < length; ++i) {
            address pool = _pools[offset + i];
            pools[i] = pool;
            configs[i] = _poolConfigs[pool];
        }
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function getPoolConfig(address pool) external view override returns (PoolConfig memory config) {
        config = _poolConfigs[pool];
        require(config.pool != address(0), PoolNotFound(pool));
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function isPoolRegistered(address pool) external view override returns (bool) {
        return _poolConfigs[pool].pool != address(0);
    }

    /**
     * @dev Authorizes UUPS upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Validates pool configuration invariants before persisting changes.
     * @param config Proposed pool configuration.
     */
    function _validateConfig(PoolConfig memory config) private pure {
        require(
            config.curator != address(0) && config.pool != address(0) && config.premiumToken != address(0)
                && config.payoutToken != address(0),
            ZeroAddress()
        );
        require(config.poolFeeBps <= _MAX_FEE_BPS && config.platformFeeBps <= _MAX_FEE_BPS, InvalidFeeBps());
    }
}
