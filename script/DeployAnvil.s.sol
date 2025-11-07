// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeployAnvil
 * @notice Deploys a CoverPool instance to a local Anvil chain.
 */
contract DeployAnvil is Deploy {
    /// @inheritdoc Deploy
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Anvil", chainId: 31_337});
    }
}
