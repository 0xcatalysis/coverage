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
     * @notice Emitted when the CoverPoolFactory address is set (deployment bootstrap).
     * @param coverPoolFactory Address of the CoverPoolFactory contract.
     */
    event CoverPoolFactorySet(address indexed coverPoolFactory);

    /**
     * @notice Emitted when a spec is registered for a pool.
     * @param coverPool Address of the CoverPool.
     * @param specId Identifier referencing the parametric product.
     * @param spec Address of the ISpec implementation contract.
     */
    event SpecRegistered(address indexed coverPool, bytes32 indexed specId, address indexed spec);

    /**
     * @notice Emitted when an admin approves a spec implementation for registration.
     * @param spec Address of the approved ISpec implementation contract.
     */
    event SpecApproved(address indexed spec);

    /**
     * @notice Emitted when an admin revokes approval for a spec implementation.
     * @param spec Address of the revoked ISpec implementation contract.
     */
    event SpecRevoked(address indexed spec);

    /**
     * @notice Reverts when spec identifier is invalid (zero).
     */
    error InvalidSpecId();

    /**
     * @notice Reverts when spec address is invalid (zero).
     */
    error InvalidSpec();

    /**
     * @notice Reverts when the caller is not a legitimate CoverPool created by CoverPoolFactory.
     */
    error InvalidCoverPool();

    /**
     * @notice Reverts when a zero address is provided where a valid address is required.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when attempting to register a different spec for an already registered (coverPool, specId) pair.
     * @param coverPool Address of the CoverPool.
     * @param specId Identifier referencing the parametric product.
     * @param existingSpec Address of the currently registered spec.
     * @param attemptedSpec Address of the spec that was attempted to be registered.
     */
    error SpecAlreadyRegistered(address coverPool, bytes32 specId, address existingSpec, address attemptedSpec);

    /**
     * @notice Reverts when resolving a spec that has not been registered.
     * @param coverPool Address of the CoverPool.
     * @param specId Identifier referencing the parametric product.
     */
    error SpecNotRegistered(address coverPool, bytes32 specId);

    /**
     * @notice Reverts when attempting to register a spec that has not been approved by the admin.
     * @param spec Address of the spec that is not on the approved whitelist.
     */
    error SpecNotApproved(address spec);

    /**
     * @notice Pauses all spec registration operations.
     * @dev Can only be called by accounts with PAUSER_ROLE.
     */
    function pause() external;

    /**
     * @notice Unpauses all spec registration operations.
     * @dev Can only be called by accounts with PAUSER_ROLE.
     */
    function unpause() external;

    /**
     * @notice Approves a spec implementation, allowing it to be registered by cover pools.
     * @dev Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *      The spec address must be a deployed contract. Re-approving is idempotent.
     * @param spec Address of the ISpec implementation contract to approve.
     */
    function approveSpec(address spec) external;

    /**
     * @notice Revokes approval for a spec implementation.
     * @dev Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *      Revocation blocks both new registrations and claim resolution via resolveSpec()
     *      for all (pool, specId) pairs that reference this spec address.
     *      Use as a targeted kill switch when a spec implementation is compromised.
     *      Re-approving the spec restores both registration and resolution.
     *      Re-revoking is idempotent.
     * @param spec Address of the ISpec implementation contract to revoke.
     */
    function revokeSpec(address spec) external;

    /**
     * @notice Returns whether a spec implementation has been approved by the admin.
     * @param spec Address of the ISpec implementation contract to query.
     * @return True if the spec is currently approved, false otherwise.
     */
    function isSpecApproved(address spec) external view returns (bool);

    /**
     * @notice Registers a Spec implementation for the caller CoverPool.
     * @dev Can only be called by a CoverPool. The spec must be admin-approved before registration.
     *      Once registered, the same (coverPool, specId) pair cannot be changed to a different spec
     *      address. Re-registering the same spec is idempotent only if the spec is still approved.
     * @param specId Identifier referencing the parametric product.
     * @param spec Address of the ISpec implementation contract.
     */
    function registerSpec(bytes32 specId, ISpec spec) external;

    /**
     * @notice Resolves the Spec contract authorized for a given CoverPool and spec identifier.
     * @dev Called by ClaimManager to determine which evaluation logic to invoke.
     * @param coverPool Address of the CoverPool requesting evaluation.
     * @param specId Identifier referencing the parametric product (e.g., MorphoSpec, MapleSpec).
     * @return spec Address of the authorized ISpec implementation contract.
     */
    function resolveSpec(address coverPool, bytes32 specId) external view returns (ISpec spec);

    /**
     * @notice AccessControl identifier for the pause role.
     */
    function PAUSER_ROLE() external view returns (bytes32);
}
