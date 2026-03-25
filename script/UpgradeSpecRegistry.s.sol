// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeBase} from "./UpgradeBase.s.sol";

/**
 * @title UpgradeSpecRegistry
 * @notice Shared upgrade logic for SpecRegistry UUPS proxy upgrades.
 * @dev Executes an upgrade via OpenZeppelin's Upgrades library.
 *
 *      WARNING: Storage layout checks are skipped. Manually verify layout before
 *      upgrading to avoid corrupting proxy state. The new `_approvedSpecs` mapping
 *      is appended after `_specs` — confirm via `out/SpecRegistry.storageLayout.json`.
 *
 *      After upgrading, the admin must call `approveSpec(specAddress)` for each trusted
 *      ISpec implementation before curators can register them in new policy bindings.
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key with DEFAULT_ADMIN_ROLE on SpecRegistry
 *        - SPEC_REGISTRY_PROXY: Address of the deployed SpecRegistry proxy (required)
 */
abstract contract UpgradeSpecRegistry is UpgradeBase {
    /**
     * @notice Provides the network name and expected chain id used for upgrade validation.
     * @dev Must be overridden by network-specific upgrade scripts.
     * @return UpgradeConfig containing network name and chain id.
     */
    function getUpgradeConfig() internal view virtual override returns (UpgradeConfig memory);

    function contractArtifact() internal pure override returns (string memory) {
        return "SpecRegistry.sol:SpecRegistry";
    }

    function proxyEnvVar() internal pure override returns (string memory) {
        return "SPEC_REGISTRY_PROXY";
    }

    function contractName() internal pure override returns (string memory) {
        return "SpecRegistry";
    }
}
