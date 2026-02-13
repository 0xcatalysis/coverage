// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ISpec} from "./interfaces/ISpec.sol";
import {ISpecRegistry} from "./interfaces/ISpecRegistry.sol";

/**
 * @title SpecRegistry
 * @notice Concrete registry for Spec implementations with immutable pool+specId mappings.
 * @dev CoverPools register specs during policy binding; ClaimManager resolves them during claims.
 *      Once a (pool, specId) pair is registered, it cannot be changed to a different spec address.
 */
contract SpecRegistry is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ISpecRegistry {
    mapping(address pool => mapping(bytes32 specId => ISpec spec)) private _specs;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the SpecRegistry with role assignments.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     */
    function initialize(address admin_) external initializer {
        require(admin_ != address(0), ZeroAddress());

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
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

        address pool = msg.sender;
        ISpec existingSpec = _specs[pool][specId];

        if (address(existingSpec) != address(0)) {
            require(
                address(existingSpec) == address(spec),
                SpecAlreadyRegistered(pool, specId, address(existingSpec), address(spec))
            );
            return;
        }

        _specs[pool][specId] = spec;
        emit SpecRegistered(pool, specId, address(spec));
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function resolveSpec(address pool, bytes32 specId) external view override returns (ISpec spec) {
        spec = _specs[pool][specId];
        require(address(spec) != address(0), SpecNotRegistered(pool, specId));
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
