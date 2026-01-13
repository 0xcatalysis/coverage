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
    address public owner;

    /**
     * @notice Emitted when a spec is registered for a specific pool and specId combination.
     * @param pool Address of the CoverPool.
     * @param specId Identifier for the spec (e.g., keccak256("MorphoSpec")).
     * @param spec Address of the ISpec implementation.
     */
    event SpecRegistered(address indexed pool, bytes32 indexed specId, address indexed spec);

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
     * @dev Restricts function access to the contract owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, NotOwner());
        _;
    }

    /**
     * @notice Deploys a new MockSpecRegistry with a default spec implementation.
     * @param defaultSpec_ Address of the default ISpec implementation to use for unregistered pool/specId pairs.
     */
    constructor(address defaultSpec_) {
        owner = msg.sender;
        _defaultSpec = defaultSpec_;
    }

    /**
     * @notice Register a spec for a specific pool and specId combination.
     * @param pool Address of the CoverPool.
     * @param specId Identifier for the spec (e.g., keccak256("MorphoSpec")).
     * @param spec Address of the ISpec implementation.
     */
    function registerSpec(address pool, bytes32 specId, address spec) external onlyOwner {
        _specs[pool][specId] = ISpec(spec);
        emit SpecRegistered(pool, specId, spec);
    }

    /**
     * @notice Update the default spec used when no pool-specific mapping exists.
     * @param spec Address of the default ISpec implementation.
     */
    function setDefaultSpec(address spec) external onlyOwner {
        _defaultSpec = spec;
        emit DefaultSpecSet(spec);
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
