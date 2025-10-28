// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ICoverPoolRegistry} from "./interfaces/ICoverPoolRegistry.sol";

/**
 * @title CoverPoolRegistry
 * @notice Stores metadata and fee configuration for Cover Pool deployments.
 * @dev UUPS upgradeable with AccessControl governance and pausability hooks.
 */
contract CoverPoolRegistry is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ICoverPoolRegistry {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    uint16 private constant _BASIS_POINTS = 10_000;

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
        require(config.poolFeeBps <= _BASIS_POINTS && config.platformFeeBps <= _BASIS_POINTS, InvalidFeeBps());
        require(uint256(config.poolFeeBps) + uint256(config.platformFeeBps) <= _BASIS_POINTS, InvalidFeeSum());
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
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        uint256 cursor,
        uint256 size
    )
        external
        view
        override
        returns (uint256[] memory poolIds, PoolConfig[] memory configs, uint256 nextCursor)
    {
        require(size != 0, InvalidPageSize());

        uint256 totalPools = _nextPoolId;
        if (totalPools == 0) {
            return (new uint256[](0), new PoolConfig[](0), 0);
        }

        if (cursor == 0) {
            cursor = 1;
        }

        if (cursor > totalPools) {
            return (new uint256[](0), new PoolConfig[](0), 0);
        }

        uint256 remaining = totalPools - cursor + 1;
        uint256 length = remaining < size ? remaining : size;

        poolIds = new uint256[](length);
        configs = new PoolConfig[](length);

        for (uint256 i = 0; i < length; ++i) {
            uint256 poolId = cursor + i;
            PoolConfig memory config = _poolConfigs[poolId];
            require(config.pool != address(0), PoolNotFound(poolId));
            poolIds[i] = poolId;
            configs[i] = config;
        }

        nextCursor = cursor + length;
        if (nextCursor > totalPools) {
            nextCursor = 0;
        }
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function resolvePool(address pool) external view override returns (uint256 poolId) {
        poolId = _poolIds[pool];
        require(poolId != 0, PoolNotRegistered(pool));
    }

    /**
     * @inheritdoc ICoverPoolRegistry
     */
    function getPoolConfig(uint256 poolId) external view override returns (PoolConfig memory) {
        PoolConfig memory config = _poolConfigs[poolId];
        require(config.pool != address(0), PoolNotFound(poolId));
        return config;
    }

    /**
     * @dev Authorises upgrades via UUPS pattern.
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
