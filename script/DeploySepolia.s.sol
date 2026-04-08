// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/**
 * @title DeploySepolia
 * @notice Deploys all Catalysis Coverage contracts to the Ethereum Sepolia testnet.
 * @dev WETH address is hardcoded for Sepolia. Catalysis Core addresses must be provided
 *      via environment variables:
 *      - SLASHING_MANAGER: Address of SlashingManager from Catalysis Core
 *      - STAKE_MANAGER: Address of StakeManager from Catalysis Core
 *      - REWARDS_MANAGER: Address of RewardsManager from Catalysis Core
 *      - CHAINLINK_PRICE_FEED: Address of ChainlinkPriceFeed
 *
 *      Usage:
 *        SLASHING_MANAGER=0x... STAKE_MANAGER=0x... REWARDS_MANAGER=0x...
 * CHAINLINK_PRICE_FEED=0x... PRIVATE_KEY=0x... \
 *          forge script script/DeploySepolia.s.sol --broadcast --rpc-url sepolia --verify
 */
contract DeploySepolia is Deploy {
    /// @notice Canonical WETH address on Ethereum Sepolia testnet.
    address internal constant WETH_SEPOLIA = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    /// @notice Circle USDC on Sepolia.
    address internal constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /**
     * @inheritdoc Deploy
     * @dev Reads PAYOUT_TOKEN from the environment. The token must match the underlying asset of
     *      the CoveredVaultWrapper's morpho vault — CoveredVaultWrapper enforces
     *      pol.payoutToken == asset() at policy binding time.
     *      Set PAYOUT_TOKEN to the same ERC-20 address used as ASSET_ADDRESS when deploying
     *      ControllableVault (e.g. WETH for a WETH-backed vault).
     */
    function getInitialPayoutTokens() internal view override returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = vm.envAddress("PAYOUT_TOKEN");
        return tokens;
    }

    /**
     * @inheritdoc Deploy
     * @dev Reads PREMIUM_TOKEN from the environment. Must equal the underlying asset of the
     *      CoveredVaultWrapper's morpho vault because the vault calls
     *      distributePremium(..., asset(), amount). If the token is not in the approved set
     *      PremiumManager reverts with TokenNotApproved on every collectPremium() call.
     *      Typically set to the same address as PAYOUT_TOKEN.
     */
    function getInitialPremiumTokens() internal view override returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = vm.envAddress("PREMIUM_TOKEN");
        return tokens;
    }

    /**
     * @inheritdoc Deploy
     * @return DeploymentConfig for Sepolia testnet (chain id 11155111).
     */
    function getDeploymentConfig() internal pure override returns (DeploymentConfig memory) {
        return DeploymentConfig({networkName: "Sepolia", chainId: 11_155_111});
    }

    /**
     * @inheritdoc Deploy
     * @dev Uses hardcoded WETH address for Sepolia. SpecRegistry, SlashingManager, StakeManager,
     *      and RewardsManager addresses must be provided via environment variables.
     * @return ExternalConfig with Sepolia WETH and env-loaded Catalysis Core addresses.
     */
    function getExternalConfig() internal view override returns (ExternalConfig memory) {
        return ExternalConfig({
            nativeWrapper: WETH_SEPOLIA,
            slashingManager: vm.envAddress("SLASHING_MANAGER"),
            chainlinkPriceFeed: vm.envAddress("CHAINLINK_PRICE_FEED"),
            stakeManager: vm.envAddress("STAKE_MANAGER"),
            rewardsManager: vm.envAddress("REWARDS_MANAGER")
        });
    }
}
