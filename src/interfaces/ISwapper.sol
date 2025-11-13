// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ISwapper
 * @notice Interface for handling token swaps to facilitate premium payments in different tokens.
 * @dev Enables buyers to pay premiums in any whitelisted token by swapping to the required premium token.
 */
interface ISwapper is IAccessControl {
    /**
     * @notice Configuration for a swap route between two tokens.
     * @dev Stores parameters needed to execute swaps through external protocols.
     */
    struct SwapRoute {
        /// @notice Source token being swapped from.
        address tokenIn;
        /// @notice Destination token being swapped to.
        address tokenOut;
        /// @notice External protocol or DEX address used for the swap.
        address swapTarget;
        /// @notice Whether this route is currently enabled.
        bool enabled;
        /// @notice Pre-configured calldata for executing swaps on the swap target.
        bytes swapCalldata;
    }

    /**
     * @notice Parameters for executing a token swap.
     * @dev Encapsulates all data needed for a single swap operation.
     */
    struct SwapParams {
        /// @notice Token being provided by the user.
        address tokenIn;
        /// @notice Token to be received after the swap.
        address tokenOut;
        /// @notice Amount of tokenIn to swap.
        uint256 amountIn;
        /// @notice Minimum amount of tokenOut expected (slippage protection).
        uint256 amountOutMin;
        /// @notice Recipient address for the swapped tokens.
        address recipient;
        /// @notice Calldata to execute on the swap target.
        bytes swapCalldata;
    }

    /**
     * @notice Emitted when a swap is successfully executed.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param amountIn Amount of tokenIn provided.
     * @param amountOut Amount of tokenOut received.
     * @param recipient Address receiving the swapped tokens.
     */
    event SwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient
    );

    /**
     * @notice Emitted when a swap route is set or updated.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param swapTarget External protocol address for the swap.
     * @param enabled Whether the route is enabled.
     */
    event SwapRouteSet(address indexed tokenIn, address indexed tokenOut, address swapTarget, bool enabled);

    /**
     * @notice Emitted when a swap target is whitelisted or removed.
     * @param target External protocol address.
     * @param whitelisted Whether the target is whitelisted.
     */
    event SwapTargetWhitelistSet(address indexed target, bool whitelisted);

    /**
     * @notice Emitted when the native token wrapper address is updated.
     * @param wrapper Address of the native token wrapper (e.g., WETH).
     */
    event NativeWrapperSet(address indexed wrapper);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a required amount is zero.
     */
    error ZeroAmount();

    /**
     * @notice Reverts when attempting to use a swap route that is not configured.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     */
    error SwapRouteNotConfigured(address tokenIn, address tokenOut);

    /**
     * @notice Reverts when attempting to use a swap target that is not whitelisted.
     * @param target External protocol address.
     */
    error SwapTargetNotWhitelisted(address target);

    /**
     * @notice Reverts when the swap output is less than the minimum expected amount.
     * @param amountOut Actual amount received.
     * @param amountOutMin Minimum expected amount.
     */
    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);

    /**
     * @notice Reverts when the swap execution fails.
     * @param reason Error reason from the swap target.
     */
    error SwapFailed(bytes reason);

    /**
     * @notice Reverts when attempting to configure a route with identical tokens.
     * @param token Address that appears as both tokenIn and tokenOut.
     */
    error IdenticalTokens(address token);

    /**
     * @notice Reverts when the balance change after swap doesn't match expectations.
     * @param expected Expected balance change.
     * @param actual Actual balance change.
     */
    error UnexpectedBalanceChange(uint256 expected, uint256 actual);

    /**
     * @notice Pauses swap operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes swap operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Whitelists or removes a swap target address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param target External protocol address.
     * @param whitelisted Whether to whitelist or remove the target.
     */
    function setSwapTargetWhitelist(address target, bool whitelisted) external;

    /**
     * @notice Sets the native token wrapper address (e.g., WETH).
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param wrapper Address of the native token wrapper contract.
     */
    function setNativeWrapper(address wrapper) external;

    /**
     * @notice Recovers tokens that are stuck in the contract.
     * @dev Requires DEFAULT_ADMIN_ROLE. Used to recover accidentally sent tokens or residual amounts.
     * @param token Address of the token to recover.
     * @param to Recipient address.
     * @param amount Amount to recover.
     */
    function recoverTokens(address token, address to, uint256 amount) external;

    /**
     * @notice Sets a swap route between two tokens.
     * @dev Requires SWAP_MANAGER_ROLE.
     *      The swapCalldata is stored and used as the default when executeSwap is called
     *      without explicit calldata. This allows ClaimManager to execute swaps without
     *      needing to know DEX-specific details.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param swapTarget External protocol address to use for swaps.
     * @param enabled Whether to enable or disable the route.
     * @param swapCalldata Pre-configured calldata for the swap target.
     */
    function setSwapRoute(
        address tokenIn,
        address tokenOut,
        address swapTarget,
        bool enabled,
        bytes calldata swapCalldata
    )
        external;

    /**
     * @notice Executes a token swap using a configured route.
     * @dev Requires SWAP_EXECUTOR_ROLE. Transfers tokenIn from caller, executes swap, and sends tokenOut to recipient.
     * @param params Swap parameters including tokens, amounts, and calldata.
     * @return amountOut Actual amount of tokenOut received.
     */
    function executeSwap(SwapParams calldata params) external returns (uint256 amountOut);

    /**
     * @notice AccessControl identifier for the swap manager role.
     */
    function SWAP_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice AccessControl identifier for the swap executor role.
     */
    function SWAP_EXECUTOR_ROLE() external view returns (bytes32);

    /**
     * @notice Address of the native token wrapper contract (e.g., WETH).
     * @return Address of the native token wrapper.
     */
    function nativeWrapper() external view returns (address);

    /**
     * @notice Returns whether a swap target is whitelisted.
     * @param target External protocol address.
     * @return whitelisted Whether the target is whitelisted.
     */
    function whitelistedTargets(address target) external view returns (bool whitelisted);

    /**
     * @notice Returns the swap route configuration for a token pair.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @return SwapRoute configuration.
     */
    function getSwapRoute(address tokenIn, address tokenOut) external view returns (SwapRoute memory);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);
}
