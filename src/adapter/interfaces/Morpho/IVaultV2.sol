// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IVaultV2
/// @notice Interface for Morpho Vault V2 (partial - only what we need)
/// @dev Full interface at https://github.com/morpho-org/vault-v2
interface IVaultV2 {
    /* VIEW FUNCTIONS */

    /// @notice Returns the underlying asset address
    function asset() external view returns (address);

    /// @notice Returns the vault's name
    function name() external view returns (string memory);

    /// @notice Returns the vault's symbol
    function symbol() external view returns (string memory);

    /// @notice Returns the vault's decimals
    function decimals() external view returns (uint8);

    /// @notice Returns the vault owner
    function owner() external view returns (address);

    /// @notice Returns the curator address
    function curator() external view returns (address);

    /// @notice Returns total assets under management
    function totalAssets() external view returns (uint256);

    /// @notice Returns total supply of shares
    function totalSupply() external view returns (uint256);

    /// @notice Returns share balance of account
    function balanceOf(
        address account
    ) external view returns (uint256);

    /// @notice Checks if address is an allocator
    function isAllocator(
        address account
    ) external view returns (bool);

    /// @notice Checks if address is a sentinel
    function isSentinel(
        address account
    ) external view returns (bool);

    /// @notice Checks if address is a registered adapter
    function isAdapter(
        address account
    ) external view returns (bool);

    /// @notice Returns allocation for a given id
    function allocation(
        bytes32 id
    ) external view returns (uint256);

    /// @notice Returns absolute cap for a given id
    function absoluteCap(
        bytes32 id
    ) external view returns (uint256);

    /// @notice Returns relative cap for a given id
    function relativeCap(
        bytes32 id
    ) external view returns (uint256);

    /// @notice Returns the liquidity adapter address
    function liquidityAdapter() external view returns (address);

    /// @notice Returns the liquidity data
    function liquidityData() external view returns (bytes memory);

    /// @notice Returns the timelock for a selector
    function timelock(
        bytes4 selector
    ) external view returns (uint256);

    /// @notice Returns whether a selector has been abdicated
    function abdicated(
        bytes4 selector
    ) external view returns (bool);

    /// @notice Returns when data becomes executable
    function executableAt(
        bytes memory data
    ) external view returns (uint256);

    /// @notice Returns the performance fee
    function performanceFee() external view returns (uint96);

    /// @notice Returns the management fee
    function managementFee() external view returns (uint96);

    /// @notice Returns the fee recipient
    function feeRecipient() external view returns (address);

    /// @notice Returns the management fee recipient
    function managementFeeRecipient() external view returns (address);

    /// @notice Returns the receive shares gate
    function receiveSharesGate() external view returns (address);

    /// @notice Returns the send shares gate
    function sendSharesGate() external view returns (address);

    /// @notice Returns the receive assets gate
    function receiveAssetsGate() external view returns (address);

    /// @notice Returns the send assets gate
    function sendAssetsGate() external view returns (address);

    /* ERC4626 FUNCTIONS */

    /// @notice Deposits assets and mints shares
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Mints shares by depositing assets
    function mint(
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);

    /// @notice Withdraws assets by burning shares
    function withdraw(
        uint256 assets,
        address receiver,
        // slither-disable-next-line shadowing-local
        address owner
    ) external returns (uint256 shares);

    /// @notice Redeems shares for assets
    function redeem(
        uint256 shares,
        address receiver,
        // slither-disable-next-line shadowing-local
        address owner
    ) external returns (uint256 assets);

    /// @notice Preview deposit
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Preview mint
    function previewMint(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Preview withdraw
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Preview redeem
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Converts assets to shares
    function convertToShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Converts shares to assets
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    /* ALLOCATOR FUNCTIONS */

    /// @notice Allocates assets to an adapter
    function allocate(
        address adapter,
        bytes memory data,
        uint256 assets
    ) external;

    /// @notice Deallocates assets from an adapter
    function deallocate(
        address adapter,
        bytes memory data,
        uint256 assets
    ) external;

    /// @notice Sets the liquidity adapter and data
    function setLiquidityAdapterAndData(
        address newLiquidityAdapter,
        bytes memory newLiquidityData
    ) external;

    /* CURATOR/OWNER FUNCTIONS */

    /// @notice Submits timelocked data
    function submit(
        bytes memory data
    ) external;

    /// @notice Adds an adapter
    function addAdapter(
        address adapter
    ) external;

    /// @notice Removes an adapter
    function removeAdapter(
        address adapter
    ) external;

    /// @notice Increases absolute cap
    function increaseAbsoluteCap(
        bytes memory idData,
        uint256 newAbsoluteCap
    ) external;

    /// @notice Decreases absolute cap
    function decreaseAbsoluteCap(
        bytes memory idData,
        uint256 newAbsoluteCap
    ) external;

    /// @notice Increases relative cap
    function increaseRelativeCap(
        bytes memory idData,
        uint256 newRelativeCap
    ) external;

    /// @notice Decreases relative cap
    function decreaseRelativeCap(
        bytes memory idData,
        uint256 newRelativeCap
    ) external;

    /// @notice Sets an allocator
    function setIsAllocator(
        address allocator,
        bool isAllocator_
    ) external;

    /// @notice Sets a sentinel
    function setSentinel(
        address sentinel,
        bool isSentinel_
    ) external;

    /// @notice Abdicates a selector
    function abdicate(
        bytes4 selector
    ) external;

    /* FORCE DEALLOCATE */

    /// @notice Force deallocates from an adapter (with penalty)
    function forceDeallocate(
        address adapter,
        bytes memory data,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 penaltyShares);

    /* INTEREST */

    /// @notice Accrues interest
    function accrueInterest() external;
}
