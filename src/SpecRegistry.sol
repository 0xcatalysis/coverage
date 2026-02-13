// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpec} from "./interfaces/ISpec.sol";
import {ISpecRegistry} from "./interfaces/ISpecRegistry.sol";

/**
 * @title SpecRegistry
 * @notice Concrete registry for Spec implementations with immutable pool+specId mappings.
 * @dev CoverPools register specs during policy binding; ClaimManager resolves them during claims.
 *      Once a (pool, specId) pair is registered, it cannot be changed to a different spec address.
 */
contract SpecRegistry is ISpecRegistry {
    mapping(address pool => mapping(bytes32 specId => ISpec spec)) private _specs;

    /**
     * @inheritdoc ISpecRegistry
     */
    function registerSpec(bytes32 specId, ISpec spec) external override {
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
}
