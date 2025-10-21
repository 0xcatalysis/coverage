// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Show} from "./Show.s.sol";

/**
 * @title ShowSepolia
 * @notice Prints configuration details for an existing Sepolia CoverPool deployment.
 */
contract ShowSepolia is Show {
    /// @inheritdoc Show
    function getShowConfig() internal pure override returns (ShowConfig memory) {
        return ShowConfig({networkName: "Sepolia", chainIdEnvKey: "SEPOLIA_CHAIN_ID", defaultChainId: 11_155_111});
    }
}
