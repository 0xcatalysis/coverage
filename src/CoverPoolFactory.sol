// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";

/**
 * @title CoverPoolFactory
 * @notice Deploys CoverPool minimal clones and keeps a lightweight registry of created pools.
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

    address public override coverPoolImplementation;
    address public override policyManager;

    address[] private _pools;
    mapping(address pool => bool registered) private _poolRegistered;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes factory configuration and admin role.
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
     * @inheritdoc ICoverPoolFactory
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ICoverPoolFactory
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
        address coverPool = coverPoolImplementation.clone();

        ICoverPool(coverPool)
            .initialize(params.curator, policyManager, params.quoteSigner, params.defaultSpecId, params.poolFeeBps);

        _pools.push(coverPool);
        _poolRegistered[coverPool] = true;

        emit CoverPoolCreated(
            coverPool, params.curator, params.quoteSigner, policyManager, params.defaultSpecId, params.poolFeeBps
        );
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
     * @inheritdoc ICoverPoolFactory
     */
    function isPoolRegistered(address pool) external view override returns (bool) {
        return _poolRegistered[pool];
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function totalPools() external view override returns (uint256) {
        return _pools.length;
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function poolAt(uint256 index) external view override returns (address) {
        require(index < _pools.length, InvalidLimit());
        return _pools[index];
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function getPools(uint256 offset, uint256 limit) external view override returns (address[] memory pools) {
        require(limit != 0, InvalidLimit());

        uint256 total = _pools.length;
        if (total == 0 || offset >= total) {
            return new address[](0);
        }

        uint256 to = offset + limit;
        if (to > total) {
            to = total;
        }

        uint256 length = to - offset;
        pools = new address[](length);

        for (uint256 i = 0; i < length; ++i) {
            pools[i] = _pools[offset + i];
        }
    }

    /**
     * @dev Authorizes UUPS upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
