// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";
import {ICoverPoolRegistry} from "./interfaces/ICoverPoolRegistry.sol";

/**
 * @title CoverPoolFactory
 * @notice Deploys CoverPool minimal clones and registers them with CoverPoolRegistry.
 * @dev UUPS upgradeable factory administering implementation, registry, and PolicyManager references.
 */
contract CoverPoolFactory is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ICoverPoolFactory
{
    using Clones for address;

    address public override coverPoolImplementation;
    address public override coverPoolRegistry;
    address public override policyManager;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes factory configuration and admin role.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param coverPoolImplementation_ Address of the CoverPool implementation contract.
     * @param coverPoolRegistry_ Address of the CoverPoolRegistry contract.
     * @param policyManager_ Address of the PolicyManager contract.
     */
    function initialize(
        address admin_,
        address coverPoolImplementation_,
        address coverPoolRegistry_,
        address policyManager_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && coverPoolImplementation_ != address(0) && coverPoolRegistry_ != address(0)
                && policyManager_ != address(0),
            ZeroAddress()
        );
        require(coverPoolImplementation_.code.length != 0, InvalidImplementation());

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        coverPoolImplementation = coverPoolImplementation_;
        coverPoolRegistry = coverPoolRegistry_;
        policyManager = policyManager_;
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function createCoverPool(CreateCoverPoolParams calldata params)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (address, uint256)
    {
        address coverPool = coverPoolImplementation.clone();

        ICoverPoolRegistry.PoolConfig memory config = ICoverPoolRegistry.PoolConfig({
            pool: coverPool,
            curator: params.curator,
            premiumToken: params.premiumToken,
            payoutToken: params.payoutToken,
            defaultSpecId: params.defaultSpecId,
            poolFeeBps: params.poolFeeBps,
            platformFeeBps: params.platformFeeBps,
            active: params.active
        });

        uint256 poolId = ICoverPoolRegistry(coverPoolRegistry).registerPool(config);

        address policyManager_ = policyManager;
        ICoverPool(coverPool).initialize(poolId, params.curator, policyManager_, params.quoteSigner);

        emit CoverPoolCreated(poolId, coverPool, params.curator, params.quoteSigner, policyManager_);

        return (coverPool, poolId);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setCoverPoolImplementation(address newImplementation) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImplementation != address(0), ZeroAddress());
        require(newImplementation.code.length != 0, InvalidImplementation());

        address previousImplementation = coverPoolImplementation;
        coverPoolImplementation = newImplementation;

        emit CoverPoolImplementationSet(previousImplementation, newImplementation);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setCoverPoolRegistry(address newRegistry) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRegistry != address(0), ZeroAddress());

        address previousRegistry = coverPoolRegistry;
        coverPoolRegistry = newRegistry;

        emit CoverPoolRegistrySet(previousRegistry, newRegistry);
    }

    /**
     * @inheritdoc ICoverPoolFactory
     */
    function setPolicyManager(address newPolicyManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPolicyManager != address(0), ZeroAddress());

        address previousPolicyManager = policyManager;
        policyManager = newPolicyManager;

        emit PolicyManagerSet(previousPolicyManager, newPolicyManager);
    }

    /**
     * @dev Authorizes UUPS upgrades.
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
