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

    uint256 private _nextPoolId;
    mapping(uint256 poolId => PoolConfig) private _poolConfigs;
    mapping(address pool => uint256 poolId) private _poolIds;

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

        uint256 poolId = ++_nextPoolId;
        _poolConfigs[poolId] = config;
        _poolIds[coverPool] = poolId;

        address policyManager_ = policyManager;
        ICoverPool(coverPool).initialize(poolId, params.curator, policyManager_, params.quoteSigner);

        emit CoverPoolCreated(poolId, coverPool, params.curator, params.quoteSigner, policyManager_);
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
        uint256 poolId,
        PoolConfig calldata newConfig
    )
        external
        override
        onlyRole(CREATOR_ROLE)
        whenNotPaused
    {
        _validateConfig(newConfig);

        PoolConfig storage config = _poolConfigs[poolId];
        require(config.pool != address(0), PoolNotFound(poolId));
        require(config.active == newConfig.active, PoolActiveStatusMismatch());

        if (newConfig.pool != config.pool) {
            delete _poolIds[config.pool];
            _poolIds[newConfig.pool] = poolId;

            config.pool = newConfig.pool;
        }

        config.curator = newConfig.curator;
        config.premiumToken = newConfig.premiumToken;
        config.payoutToken = newConfig.payoutToken;
        config.defaultSpecId = newConfig.defaultSpecId;
        config.poolFeeBps = newConfig.poolFeeBps;
        config.platformFeeBps = newConfig.platformFeeBps;

        emit PoolConfigUpdated(poolId, config);
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function setPoolStatus(uint256 poolId, bool active) external override onlyRole(CREATOR_ROLE) {
        PoolConfig storage config = _poolConfigs[poolId];
        require(config.pool != address(0), PoolNotFound(poolId));
        require(config.active != active, PoolStatusUnchanged());

        config.active = active;

        emit PoolStatusSet(poolId, active);
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
        returns (uint256[] memory poolIds, PoolConfig[] memory configs)
    {
        require(limit != 0, InvalidLimit());

        uint256 totalPools = _nextPoolId;
        if (totalPools == 0 || offset >= totalPools) {
            return (new uint256[](0), new PoolConfig[](0));
        }

        uint256 to = Paginator.getTo(totalPools, offset, limit);
        uint256 length = to - offset;
        if (length == 0) {
            return (new uint256[](0), new PoolConfig[](0));
        }

        poolIds = new uint256[](length);
        configs = new PoolConfig[](length);

        uint256 startId = offset + 1;
        for (uint256 i = 0; i < length; ++i) {
            uint256 poolId = startId + i;
            PoolConfig memory config = _poolConfigs[poolId];
            require(config.pool != address(0), PoolNotFound(poolId));
            poolIds[i] = poolId;
            configs[i] = config;
        }
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function getPoolConfig(uint256 poolId) external view override returns (PoolConfig memory config) {
        config = _poolConfigs[poolId];
        require(config.pool != address(0), PoolNotFound(poolId));
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function resolvePool(address pool) external view override returns (uint256 poolId) {
        poolId = _poolIds[pool];
        require(poolId != 0, PoolNotRegistered(pool));
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
