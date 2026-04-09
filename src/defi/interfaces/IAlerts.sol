// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IAlerts
/// @notice Error definitions for Catalysis protocol adapters
/// @dev Shared error interface used across multiple contracts in the protocol.
///      Some errors may appear unused in this repo but are used in other protocol contracts.
interface IAlerts {
    /// @notice Thrown when sender is not authorized
    // aderyn-fp-next-line(unused-error) Used in Bundler3 adapter
    error UnauthorizedSender();

    /// @notice Thrown when invalid parameters are provided
    // aderyn-fp-next-line(unused-error) Used in CoverHookAdapter
    error InvalidParameters();

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when receiver is the adapter address itself
    // aderyn-fp-next-line(unused-error) Used in Bundler3 adapter
    error AdapterAddress();

    /// @notice Thrown when slippage exceeds tolerance
    // aderyn-fp-next-line(unused-error) Used in Bundler3 adapter
    error SlippageExceeded();

    /// @notice Thrown when user has insufficient NAV/shares
    // aderyn-fp-next-line(unused-error) Used in Bundler3 adapter
    error InsufficientNav();

    /// @notice Thrown when policy is invalid for the operation
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error InvalidPolicy();

    /// @notice Thrown when policy is not found
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error PolicyNotFound();

    /// @notice Thrown when policy has expired
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error PolicyExpired();

    /// @notice Thrown when policy hasn't started yet
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error PolicyNotStarted();

    /// @notice Thrown when policy owner doesn't match
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error InvalidPolicyOwner();

    /// @notice Thrown when cover pool doesn't match
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error InvalidCoverPool();

    /// @notice Thrown when payout receiver doesn't match
    // aderyn-fp-next-line(unused-error) Used in PolicyInteractions base
    error InvalidPayoutReceiver();

    /// @notice Thrown when max coverable loss bps is invalid (0 or > 10000)
    error InvalidMaxCoverableLoss();

    /// @notice Thrown when parentVault and underlyingVault are the same address
    // aderyn-fp-next-line(unused-error) Reserved for external protocol integrations
    error SameVault();

    /// @notice Thrown when policyId is zero (adapter requires a valid policy)
    // aderyn-fp-next-line(unused-error) Reserved for external protocol integrations
    error ZeroPolicyId();

    /// @notice Thrown when trying to make a partial withdrawal during deallocate / forceDeallocate
    error WithdrawAllOnlyDuringDealoc();

    /// @notice Thrown when unsupported deallocation is processed
    /**
     * @dev Supported deallocations include:
     *  - Deallocation / Force Deallocation with full withdrawal from underlying Vault.
     *  - Management fee recepient's share redemption without coverage claiming.
     *  - Share redemption for valid users.
     */
    error UnsupportedDeallocation(uint256 assets, bytes4 selector, address sender);

    /// @notice Thrown when not owner of Covered Vault tries to upgrade adapter.
    error NotAuthorizedUpgrader(address account);

    /// @notice Thrown when a Morpho deposit returns zero shares (dust deposit protection).
    error ZeroSharesReceived();

    /// @notice Thrown when the proposed premium recipient does not implement IPremiumManager.
    error InvalidPremiumRecipient();
}
