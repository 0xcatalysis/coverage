// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeBase} from "./UpgradeBase.s.sol";

/**
 * @title UpgradeClaimManager
 * @notice Shared upgrade logic for ClaimManager UUPS proxy upgrades.
 * @dev Executes an upgrade via OpenZeppelin's Upgrades library.
 *
 *      WARNING: Storage layout checks are skipped. Manually verify layout before
 *      upgrading to avoid corrupting proxy state.
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key with DEFAULT_ADMIN_ROLE on ClaimManager
 *        - CLAIM_MANAGER_PROXY: Address of the deployed ClaimManager proxy (required)
 */
abstract contract UpgradeClaimManager is UpgradeBase {
    /**
     * @notice Provides the network name and expected chain id used for upgrade validation.
     * @dev Must be overridden by network-specific upgrade scripts.
     * @return UpgradeConfig containing network name and chain id.
     */
    function getUpgradeConfig() internal view virtual override returns (UpgradeConfig memory);

    function contractArtifact() internal pure override returns (string memory) {
        return "ClaimManager.sol:ClaimManager";
    }

    function proxyEnvVar() internal pure override returns (string memory) {
        return "CLAIM_MANAGER_PROXY";
    }

    function contractName() internal pure override returns (string memory) {
        return "ClaimManager";
    }
}
