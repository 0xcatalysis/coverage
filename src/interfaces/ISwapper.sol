// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

/**
 * @title ISwapper
 * @notice Interface for converting slashed collateral into payout tokens during claim settlements.
 * @dev Used by ClaimManager to convert various collateral types (ETH, wBTC) received from slashing
 *      into the policy's designated payout token (USDC, DAI, etc.) via pre-approved DEX routes.
 */
interface ISwapper is IAccessControlDefaultAdminRules {
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
     * @notice Reverts when attempting to use a swap route that is not enabled.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     */
    error SwapRouteNotEnabled(address tokenIn, address tokenOut);

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
     * @notice Reverts when native ETH is sent but ERC20 swap was expected.
     */
    error UnexpectedNativePayment();

    /**
     * @notice Reverts when insufficient native ETH is sent for a native swap.
     * @param sent Amount of native ETH sent.
     * @param required Amount of native ETH required.
     */
    error InsufficientNativeAmount(uint256 sent, uint256 required);

    /**
     * @notice Reverts when native ETH transfer fails.
     */
    error NativeTransferFailed();

    /**
     * @notice Reverts when attempting to configure a route using NATIVE_ETH instead of nativeWrapper.
     * @param token The NATIVE_ETH constant that was incorrectly used.
     */
    error InvalidRouteToken(address token);

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
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param swapTarget External protocol address to use for swaps.
     * @param enabled Whether to enable or disable the route.
     */
    function setSwapRoute(address tokenIn, address tokenOut, address swapTarget, bool enabled) external;

    /**
     * @notice Executes a token swap using a configured route.
     * @dev Requires SWAP_EXECUTOR_ROLE (typically granted to ClaimManager).
     *
     *      Native ETH Handling:
     *      - Use NATIVE_ETH (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) for tokenIn or tokenOut
     *      - When tokenIn is NATIVE_ETH, send ETH via msg.value (wraps to WETH automatically)
     *      - When tokenOut is NATIVE_ETH, recipient receives unwrapped ETH
     *      - Routes must be configured using nativeWrapper address (WETH), not NATIVE_ETH
     *
     *      Execution Flow:
     *      1. Validates route configuration and whitelist status
     *      2. If tokenIn is NATIVE_ETH, wraps msg.value to WETH; else pulls ERC20 via transferFrom
     *      3. Approves swapTarget for the input amount
     *      4. Executes swap via external call with provided swapCalldata
     *      5. Verifies output amount via balance diff (trustless verification)
     *      6. Clears approval to minimize attack surface
     *      7. If tokenOut is NATIVE_ETH, unwraps WETH and sends ETH; else transfers ERC20
     *
     *      Typical ClaimManager Usage:
     *      - ClaimManager receives slashed collateral (ETH or WETH) from SlashingManager
     *      - For ERC20: ClaimManager approves Swapper for collateral amount
     *      - For native ETH: ClaimManager sends ETH via msg.value
     *      - ClaimManager calls executeSwap with recipient as PremiumReserve or beneficiary
     *      - Swapper converts collateral → payout token and sends to recipient
     *
     * @param params Swap parameters including tokens, amounts, slippage limits, recipient, and DEX calldata.
     * @return amountOut Actual amount of tokenOut received and transferred to recipient.
     */
    function executeSwap(SwapParams calldata params) external payable returns (uint256 amountOut);

    /**
     * @notice AccessControl identifier for the swap manager role.
     */
    function SWAP_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice AccessControl identifier for the swap executor role.
     */
    function SWAP_EXECUTOR_ROLE() external view returns (bytes32);

    /**
     * @notice Canonical address representing native ETH in swap operations.
     * @dev Use this constant as tokenIn or tokenOut in executeSwap to swap native ETH.
     *      Always returns 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE.
     *      Routes must be configured using the nativeWrapper address (WETH), not this constant.
     * @return Address used to denote native ETH in executeSwap calls.
     */
    function NATIVE_ETH() external pure returns (address);

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

