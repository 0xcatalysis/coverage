// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ISpec} from "./interfaces/ISpec.sol";
import {ISpecRegistry} from "./interfaces/ISpecRegistry.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";

/**
 * @title SpecRegistry
 * @notice Concrete registry for Spec implementations with immutable coverPool+specId mappings.
 * @dev CoverPools register specs during policy binding; ClaimManager resolves them during claims.
 *      Once a (coverPool, specId) pair is registered, it cannot be changed to a different spec address.
 */
contract SpecRegistry is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ISpecRegistry {
    ICoverPoolFactory public coverPoolFactory;

    mapping(address coverPool => mapping(bytes32 specId => ISpec spec)) private _specs;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the SpecRegistry with role assignments.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param coverPoolFactory_ Address of the CoverPoolFactory contract (may be zero; set via setCoverPoolFactory).
     */
    function initialize(address admin_, address coverPoolFactory_) external initializer {
        require(admin_ != address(0), ZeroAddress());

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (coverPoolFactory_ != address(0)) {
            coverPoolFactory = ICoverPoolFactory(coverPoolFactory_);
        }
    }

    /**
     * @notice Sets the CoverPoolFactory address (deployment bootstrap for circular dependency).
     * @dev May only be called once when coverPoolFactory is unset. Restricted to DEFAULT_ADMIN_ROLE.
     * @param coverPoolFactory_ Address of the CoverPoolFactory contract.
     */
    function setCoverPoolFactory(address coverPoolFactory_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(coverPoolFactory_ != address(0), ZeroAddress());
        require(address(coverPoolFactory) == address(0), "CoverPoolFactory already set");
        coverPoolFactory = ICoverPoolFactory(coverPoolFactory_);
        emit CoverPoolFactorySet(coverPoolFactory_);
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function registerSpec(bytes32 specId, ISpec spec) external override whenNotPaused {
        require(specId != bytes32(0), InvalidSpecId());
        require(address(spec) != address(0), InvalidSpec());
        require(address(spec).code.length > 0, InvalidSpec());
        require(address(coverPoolFactory) != address(0), ZeroAddress());

        address coverPool = msg.sender;
        require(coverPoolFactory.coverPoolExists(coverPool), InvalidCoverPool());
        ISpec existingSpec = _specs[coverPool][specId];

        if (address(existingSpec) != address(0)) {
            require(
                address(existingSpec) == address(spec),
                SpecAlreadyRegistered(coverPool, specId, address(existingSpec), address(spec))
            );
            return;
        }

        _specs[coverPool][specId] = spec;
        emit SpecRegistered(coverPool, specId, address(spec));
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function resolveSpec(address coverPool, bytes32 specId) external view override returns (ISpec spec) {
        spec = _specs[coverPool][specId];
        require(address(spec) != address(0), SpecNotRegistered(coverPool, specId));
        return spec;
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function paused() public view override (ISpecRegistry, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImplementation != address(0), ZeroAddress());
    }
}
