// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IPremiumCollector
 * @notice Interface for collecting ERC-4626 vault shares, redeeming them to underlying assets,
 * and distributing premiums to PremiumManager.
 */
interface IPremiumCollector is IAccessControl {
    /**
     * @notice Configuration for a registered ERC-4626 vault.
     */
    struct VaultConfig {
        /// @notice ERC-20 underlying asset from ERC-4626 redeem.
        address underlying;
        /// @notice CoverPool for fee routing (poolFeeBps, poolFeeRecipient).
        address pool;
        /// @notice RewardsManager routing committee identifier.
        uint96 committeeId;
        /// @notice RewardsManager routing operator address.
        address operator;
        /// @notice Timestamp of most recent distribute for this vault.
        uint64 lastDistributeTime;
        /// @notice Active flag indicating if vault is registered.
        bool registered;
    }

    /**
     * @notice Emitted when a vault is registered.
     * @param vault Address of the ERC-4626 vault.
     * @param underlying Address of the underlying asset.
     * @param pool Address of the CoverPool.
     * @param committeeId Committee identifier for rewards routing.
     * @param operator Operator address for rewards routing.
     */
    event VaultRegistered(
        address indexed vault, address indexed underlying, address pool, uint96 committeeId, address operator
    );

    /**
     * @notice Emitted when a vault is removed.
     * @param vault Address of the ERC-4626 vault.
     */
    event VaultRemoved(address indexed vault);

    /**
     * @notice Emitted when a vault configuration is updated.
     * @param vault Address of the ERC-4626 vault.
     * @param pool New CoverPool address.
     * @param committeeId New committee identifier.
     * @param operator New operator address.
     */
    event VaultUpdated(address indexed vault, address pool, uint96 committeeId, address operator);

    /**
     * @notice Emitted when shares are redeemed and distributed.
     * @param vault Address of the ERC-4626 vault.
     * @param shares Amount of shares redeemed.
     * @param assets Amount of underlying assets received.
     */
    event Distributed(address indexed vault, uint256 shares, uint256 assets);

    /**
     * @notice Emitted when the distribute interval is updated.
     * @param interval New distribute interval in seconds.
     */
    event DistributeIntervalSet(uint64 interval);

    /**
     * @notice Emitted when the PremiumManager dependency is set or updated.
     * @param premiumManager_ Address of the premium manager contract.
     */
    event PremiumManagerSet(address indexed premiumManager_);

    /**
     * @notice Reverts when attempting to register a vault that's already registered.
     * @param vault Address of the vault.
     */
    error VaultAlreadyRegistered(address vault);

    /**
     * @notice Reverts when attempting to operate on an unregistered vault.
     * @param vault Address of the vault.
     */
    error VaultNotRegistered(address vault);

    /**
     * @notice Reverts when attempting to remove a vault that still has shares.
     * @param vault Address of the vault.
     * @param shares Amount of remaining shares.
     */
    error VaultHasShares(address vault, uint256 shares);

    /**
     * @notice Reverts when a zero address is provided where not allowed.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a zero amount is provided where not allowed.
     */
    error ZeroAmount();

    /**
     * @notice Reverts when an invalid distribute interval is provided.
     * @param interval Invalid interval value.
     */
    error InvalidDistributeInterval(uint64 interval);

    /**
     * @notice Pauses distribution operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes distribution operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Registers a new ERC-4626 vault for premium collection.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     *      Automatically reads the underlying asset from the vault's asset() method.
     * @param vault Address of the ERC-4626 vault.
     * @param pool Address of the CoverPool for fee routing.
     * @param committeeId Committee identifier for rewards routing.
     * @param operator Operator address for rewards routing.
     */
    function registerVault(address vault, address pool, uint96 committeeId, address operator) external;

    /**
     * @notice Removes a vault from the registry.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     *      Reverts if the vault has outstanding shares.
     * @param vault Address of the ERC-4626 vault to remove.
     */
    function removeVault(address vault) external;

    /**
     * @notice Updates the configuration for a registered vault.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param vault Address of the ERC-4626 vault.
     * @param pool New CoverPool address.
     * @param committeeId New committee identifier.
     * @param operator New operator address.
     */
    function updateVault(address vault, address pool, uint96 committeeId, address operator) external;

    /**
     * @notice Distributes premiums for multiple vaults in a single transaction.
     * @dev Public function callable by anyone (typically a keeper).
     *      Skips vaults where the interval has not elapsed or share balance is zero.
     *      Protected with nonReentrant + whenNotPaused.
     * @param vaults Array of vault addresses to process.
     */
    function distributeBatch(address[] calldata vaults) external;

    /**
     * @notice Sets the minimum interval between distributions for each vault.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param interval Minimum seconds between distributions (default: 86400 = 24h).
     */
    function setDistributeInterval(uint64 interval) external;

    /**
     * @notice Sets the PremiumManager contract used for premium distribution.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address of the PremiumManager implementation.
     */
    function setPremiumManager(address premiumManager_) external;

    /**
     * @notice Returns the list of all registered vaults.
     * @return Array of registered vault addresses.
     */
    function getRegisteredVaults() external view returns (address[] memory);

    /**
     * @notice Returns the configuration for a registered vault.
     * @param vault Address of the vault.
     * @return config Vault configuration struct.
     */
    function getVaultConfig(address vault) external view returns (VaultConfig memory config);

    /**
     * @notice Returns the current share balance for a vault held by this contract.
     * @param vault Address of the ERC-4626 vault.
     * @return shares Current share balance.
     */
    function getAccruedShares(address vault) external view returns (uint256 shares);

    /**
     * @notice Returns vaults that are eligible for distribution.
     * @dev Filters registered vaults where:
     *      - block.timestamp >= lastDistributeTime + distributeInterval
     *      - balanceOf(this) > 0
     * @return Array of vault addresses eligible for distribution.
     */
    function getDistributableVaults() external view returns (address[] memory);

    /**
     * @notice Returns the configured PremiumManager address.
     */
    function premiumManager() external view returns (address);

    /**
     * @notice Returns the distribute interval in seconds.
     */
    function distributeInterval() external view returns (uint64);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);
}
