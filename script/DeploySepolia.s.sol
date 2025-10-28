// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeploySepolia
 * @notice Deploys a CoverPool instance to the Ethereum Sepolia test network.
 */
contract DeploySepolia is Deploy {
    /// @inheritdoc Deploy
    function getDeploymentConfig() internal view override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
