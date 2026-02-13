// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpec} from "./ISpec.sol";

/**
 * @title ISpecRegistry
 * @notice Registry for versioned Spec implementations and pool authorizations.
 * @dev Third-party implementation; authorizes which Specs can be used by which pools.
 */
interface ISpecRegistry {
    /**
     * @notice Emitted when a spec is registered for a pool.
     * @param pool Address of the CoverPool.
     * @param specId Identifier referencing the parametric product.
     * @param spec Address of the ISpec implementation contract.
     */
    event SpecRegistered(address indexed pool, bytes32 indexed specId, address indexed spec);

    /**
     * @notice Reverts when spec identifier is invalid (zero).
     */
    error InvalidSpecId();

    /**
     * @notice Reverts when spec address is invalid (zero).
     */
    error InvalidSpec();

    /**
     * @notice Reverts when attempting to register a different spec for an already registered (pool, specId) pair.
     * @param pool Address of the CoverPool.
     * @param specId Identifier referencing the parametric product.
     * @param existingSpec Address of the currently registered spec.
     * @param attemptedSpec Address of the spec that was attempted to be registered.
     */
    error SpecAlreadyRegistered(address pool, bytes32 specId, address existingSpec, address attemptedSpec);

    /**
     * @notice Reverts when resolving a spec that has not been registered.
     * @param pool Address of the CoverPool.
     * @param specId Identifier referencing the parametric product.
     */
    error SpecNotRegistered(address pool, bytes32 specId);

    /**
     * @notice Registers a Spec implementation for the caller pool.
     * @dev Can only be called by a CoverPool. Once registered, the same (pool, specId) pair
     *      cannot be changed to a different spec address. Re-registering the same spec is idempotent.
     * @param specId Identifier referencing the parametric product.
     * @param spec Address of the ISpec implementation contract.
     */
    function registerSpec(bytes32 specId, ISpec spec) external;

    /**
     * @notice Resolves the Spec contract authorized for a given pool and spec identifier.
     * @dev Called by ClaimManager to determine which evaluation logic to invoke.
     * @param pool Address of the CoverPool requesting evaluation.
     * @param specId Identifier referencing the parametric product (e.g., MorphoSpec, MapleSpec).
     * @return spec Address of the authorized ISpec implementation contract.
     */
    function resolveSpec(address pool, bytes32 specId) external view returns (ISpec spec);
}
