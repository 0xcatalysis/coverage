// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Show} from "./Show.s.sol";

/**
 * @title ShowEthereum
 * @notice Prints configuration details for an existing Ethereum CoverPool deployment.
 */
contract ShowEthereum is Show {
    /// @inheritdoc Show
    function getShowConfig() internal pure override returns (ShowConfig memory) {
        return ShowConfig({networkName: "Ethereum", chainIdEnvKey: "ETHEREUM_CHAIN_ID", defaultChainId: 1});
    }
}
