// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpec} from "../interfaces/ISpec.sol";
import {ISpecRegistry} from "../interfaces/ISpecRegistry.sol";

/**
 * @title MockSpecRegistry
 * @notice Mock Spec Registry for Sepolia testing
 * @dev Allows dynamic registration of spec implementations for different pools.
 *      Provides flexible claim evaluation without real oracle dependencies.
 */
contract MockSpecRegistry is ISpecRegistry {
    mapping(address pool => mapping(bytes32 specId => ISpec spec)) private _specs;
    address private _defaultSpec;
    address public immutable OWNER;
    bool private _paused;

    /**
     * @notice Emitted when the default spec is updated.
     * @param spec Address of the new default ISpec implementation.
     */
    event DefaultSpecSet(address indexed spec);

    /**
     * @notice Thrown when caller is not the owner.
     */
    error NotOwner();

    /**
     * @notice Thrown when no spec is registered for the requested pool and specId combination.
     */
    error NoSpecRegistered();

    /**
     * @notice Thrown when attempting to perform an action while paused.
     */
    error EnforcedPause();

    /**
     * @dev Restricts function access to the contract owner.
     */
    modifier onlyOwner() {
        require(msg.sender == OWNER, NotOwner());
        _;
    }

    /**
     * @dev Restricts function execution when the contract is paused.
     */
    modifier whenNotPaused() {
        require(!_paused, EnforcedPause());
        _;
    }

    /**
     * @notice Deploys a new MockSpecRegistry with a default spec implementation.
     * @param defaultSpec_ Address of the default ISpec implementation to use for unregistered pool/specId pairs.
     */
    constructor(address defaultSpec_) {
        require(defaultSpec_ != address(0), ZeroAddress());
        OWNER = msg.sender;
        _defaultSpec = defaultSpec_;
    }

    /**
     * @inheritdoc ISpecRegistry
     * @dev In MockSpecRegistry, this uses msg.sender as the pool address.
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
     * @notice Register a spec for a specific pool and specId combination (admin function).
     * @param pool Address of the CoverPool.
     * @param specId Identifier for the spec (e.g., keccak256("MorphoSpec")).
     * @param spec Address of the ISpec implementation.
     */
    function registerSpecForPool(address pool, bytes32 specId, address spec) external onlyOwner whenNotPaused {
        _specs[pool][specId] = ISpec(spec);
        emit SpecRegistered(pool, specId, spec);
    }

    /**
     * @notice Update the default spec used when no pool-specific mapping exists.
     * @param spec Address of the default ISpec implementation.
     */
    function setDefaultSpec(address spec) external onlyOwner {
        require(spec != address(0), ZeroAddress());
        _defaultSpec = spec;
        emit DefaultSpecSet(spec);
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function pause() external override onlyOwner {
        _paused = true;
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function unpause() external override onlyOwner {
        _paused = false;
    }

    /**
     * @inheritdoc ISpecRegistry
     */
    function paused() external view override returns (bool) {
        return _paused;
    }

    /**
     * @inheritdoc ISpecRegistry
     * @dev Returns pool-specific spec if registered, otherwise returns default spec.
     */
    function resolveSpec(address pool, bytes32 specId) external view override returns (ISpec spec) {
        spec = _specs[pool][specId];
        if (address(spec) == address(0)) {
            spec = ISpec(_defaultSpec);
        }

        require(address(spec) != address(0), NoSpecRegistered());
        return spec;
    }
}
