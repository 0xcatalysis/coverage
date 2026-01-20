// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";
import {IStakeManager} from "./interfaces/IStakeManager.sol";

/**
 * @title CoverPoolFactory
 * @notice Deploys CoverPool minimal clones and keeps a lightweight registry of created pools.
 */
contract CoverPoolFactory is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ICoverPoolFactory
{
    using Clones for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant override CREATOR_ROLE = keccak256("CREATOR_ROLE");

    address public override coverPoolImplementation;
    address public override policyManager;

    EnumerableSet.AddressSet private _pools;

    address public override stakeManager;

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
        address policyManager_,
        address stakeManager_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && creator_ != address(0) && coverPoolImplementation_ != address(0)
                && policyManager_ != address(0) && stakeManager_ != address(0),
            ZeroAddress()
        );

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CREATOR_ROLE, creator_);

        coverPoolImplementation = coverPoolImplementation_;
        policyManager = policyManager_;
        stakeManager = stakeManager_;
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
        bytes32 salt = _computeSalt(params);

        address coverPool = coverPoolImplementation.cloneDeterministic(salt);
        ICoverPool(coverPool).initialize(params.curator, policyManager, params.quoteSigner, params.poolFeeBps);

        // slither-disable-next-line unused-return
        _pools.add(coverPool);

        emit CoverPoolCreated(coverPool, params.curator, params.quoteSigner, policyManager, params.poolFeeBps);

        if (!IStakeManager(stakeManager).isOperatorRegisteredToNetwork(params.curator)) {
            IStakeManager(stakeManager).registerOperatorToNetwork(params.curator, params.deadline, params.signature);
        }
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setCoverPoolImplementation(address implementation_) external override onlyRole(CREATOR_ROLE) {
        require(implementation_ != address(0), ZeroAddress());

        address previousImplementation = coverPoolImplementation;
        coverPoolImplementation = implementation_;

        emit CoverPoolImplementationSet(previousImplementation, implementation_);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setPolicyManager(address policyManager_) external override onlyRole(CREATOR_ROLE) {
        require(policyManager_ != address(0), ZeroAddress());

        address previousPolicyManager = policyManager;
        policyManager = policyManager_;

        emit PolicyManagerSet(previousPolicyManager, policyManager_);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setStakeManager(address stakeManager_) external override onlyRole(CREATOR_ROLE) {
        require(stakeManager_ != address(0), ZeroAddress());

        address previousStakeManager = stakeManager;
        stakeManager = stakeManager_;

        emit StakeManagerSet(previousStakeManager, stakeManager_);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function coverPoolExists(address pool) external view override returns (bool) {
        return _pools.contains(pool);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function coverPoolAt(uint256 index) external view override returns (address) {
        require(index < _pools.length(), InvalidLimit());
        return _pools.at(index);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function totalCoverPools() external view override returns (uint256) {
        return _pools.length();
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function getCoverPools(uint256 offset, uint256 limit) external view override returns (address[] memory) {
        require(limit != 0, InvalidLimit());

        uint256 total = _pools.length();
        if (total == 0 || offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        return _pools.values(offset, end);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function computeCoverPoolAddress(CreateCoverPoolParams calldata params) public view override returns (address) {
        bytes32 salt = _computeSalt(params);
        return coverPoolImplementation.predictDeterministicAddress(salt, address(this));
    }

    /**
     * @dev Authorizes UUPS upgrades.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImplementation != address(0), ZeroAddress());
    }

    /**
     * @dev Computes the deterministic salt used with CREATE2.
     * @param params Deployment inputs for the pool that anchor address derivation.
     * @return Salt that uniquely identifies the pool for a given implementation and policy manager.
     */
    function _computeSalt(CreateCoverPoolParams calldata params) private view returns (bytes32) {
        return EfficientHashLib.hash(
            uint256(uint160(params.curator)),
            uint256(uint160(policyManager)),
            uint256(uint160(params.quoteSigner)),
            uint256(params.poolFeeBps)
        );
    }
}
