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
     * @notice Resolves the Spec contract authorized for a given pool and spec identifier.
     * @dev Called by ClaimManager to determine which evaluation logic to invoke.
     * @param pool Address of the CoverPool requesting evaluation.
     * @param specId Identifier referencing the parametric product (e.g., MorphoSpec, MapleSpec).
     * @return spec Address of the authorized ISpec implementation contract.
     */
    function resolveSpec(address pool, bytes32 specId) external view returns (ISpec spec);
}
