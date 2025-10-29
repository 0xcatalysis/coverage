// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Paginator} from "@solarity/contracts/libs/arrays/Paginator.sol";
import {ICoverPoolRegistry} from "./interfaces/ICoverPoolRegistry.sol";

/**
 * @title CoverPoolRegistry
 * @notice Stores metadata and fee configuration for Cover Pool deployments.
 * @dev UUPS upgradeable with AccessControl governance and pausability hooks.
 */
contract CoverPoolRegistry is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ICoverPoolRegistry
{
    bytes32 public constant override REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    uint16 private constant _BASIS_POINTS = 10_000;
    uint16 private constant _MAX_FEE_BPS = 2000;

    uint256 private _nextPoolId;
    mapping(uint256 poolId => PoolConfig) private _poolConfigs;
    mapping(address pool => uint256 poolId) private _poolIds;

    /**
     * @notice Validation guard ensuring supplied pool configuration is well-formed.
     * @dev Reverts with `ZeroAddress` or fee errors before executing the wrapped function.
     */
    modifier validateConfig(PoolConfig calldata config) {
        require(
            config.curator != address(0) && config.pool != address(0) && config.premiumToken != address(0)
                && config.payoutToken != address(0),
            ZeroAddress()
        );
        require(config.poolFeeBps <= _MAX_FEE_BPS && config.platformFeeBps <= _MAX_FEE_BPS, InvalidFeeBps());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the registry and grants the admin and registrar roles.
     * @param admin Address that should receive DEFAULT_ADMIN_ROLE.
     * @param registrar Address that should receive REGISTRAR_ROLE.
     */
    function initialize(address admin, address registrar) external initializer {
        require(admin != address(0) && registrar != address(0), ZeroAddress());

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, registrar);
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
     * @inheritdoc ICoverPoolRegistry
     */
    function registerPool(PoolConfig calldata config)
        external
        override
        onlyRole(REGISTRAR_ROLE)
        whenNotPaused
        validateConfig(config)
        returns (uint256 poolId)
    {
        require(_poolIds[config.pool] == 0, PoolAlreadyRegistered(config.pool));

        poolId = ++_nextPoolId;
        _poolConfigs[poolId] = config;
        _poolIds[config.pool] = poolId;

        emit PoolRegistered(poolId, config.pool, config.curator, config);
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
        onlyRole(REGISTRAR_ROLE)
        whenNotPaused
        validateConfig(newConfig)
    {
        PoolConfig storage config = _poolConfigs[poolId];
        require(config.pool != address(0), PoolNotFound(poolId));
        require(config.active == newConfig.active, PoolActiveStatusMismatch());

        if (newConfig.pool != config.pool) {
            uint256 mappedPoolId = _poolIds[newConfig.pool];
            require(mappedPoolId == 0, PoolAlreadyRegistered(newConfig.pool));

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
    function setPoolStatus(uint256 poolId, bool active) external override onlyRole(REGISTRAR_ROLE) {
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
     * @dev Authorizes upgrades via UUPS pattern.
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
