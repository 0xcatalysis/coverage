// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Minimal Uniswap V3 SwapRouter02 interface.
 * @dev Avoids importing the full Uniswap dependency tree.
 *      Based on https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/interfaces/IV3SwapRouter.sol
 */
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title UniswapV3Adapter
 * @notice Bridges the Swapper's static-calldata pattern to Uniswap V3 SwapRouter02.
 * @dev The Swapper stores static calldata per route and replays it verbatim on every swap.
 *      Uniswap V3's `exactInputSingle` requires `amountIn` to be encoded in each call, making
 *      a direct route impossible for variable claim amounts.
 *
 *      This adapter is registered as the `swapTarget` in Swapper routes. The stored route
 *      calldata encodes `swap(tokenIn, tokenOut, fee, amountOutMinimum)` — all static per route,
 *      with `amountOutMinimum` encoded as `0` so the Swapper's own slippage check is the primary
 *      guard. At execution time, the adapter dynamically resolves `amountIn` from the Swapper's
 *      ERC-20 approval.
 *
 *      Integration pattern (called by Swapper._performSwap):
 *        1. Swapper approves adapter for `amountIn` of tokenIn
 *        2. Swapper calls `swap(tokenIn, tokenOut, fee, amountOutMinimum)` via stored calldata
 *        3. Adapter reads allowance to obtain amountIn
 *        4. Adapter pulls tokenIn from Swapper via transferFrom
 *        5. Adapter approves SwapRouter02 for amountIn
 *        6. Adapter calls exactInputSingle with recipient = Swapper (msg.sender)
 *        7. SwapRouter02 sends tokenOut directly to Swapper
 *        8. Swapper measures balance diff to determine amountOut
 *        9. Adapter clears residual approval to SwapRouter02
 *
 *      Deployment: deployed separately from the main Coverage suite; configured via
 *      Swapper.setSwapTargetWhitelist() and Swapper.setSwapRoute() by SWAP_MANAGER_ROLE.
 *
 *      Sepolia SwapRouter02: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
 */
contract UniswapV3Adapter {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a swap is executed through the adapter.
    event AdapterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    /// @notice Reverts when called with a zero address.
    error ZeroAddress();

    /// @notice Reverts when the allowance read from the caller is zero.
    error ZeroAllowance();

    /// @notice Uniswap V3 SwapRouter02 address (immutable, set at construction).
    IV3SwapRouter public immutable SWAP_ROUTER;

    /**
     * @notice Deploys the adapter pointing at a specific SwapRouter02 instance.
     * @param swapRouter_ Uniswap V3 SwapRouter02 address.
     *                    Sepolia: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
     *                    Mainnet: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
     */
    constructor(address swapRouter_) {
        require(swapRouter_ != address(0), ZeroAddress());
        SWAP_ROUTER = IV3SwapRouter(swapRouter_);
    }

    /**
     * @notice Executes a single-hop Uniswap V3 swap on behalf of the Swapper.
     * @dev Called by the Swapper via stored route calldata. The `amountIn` is resolved
     *      dynamically from `allowance(msg.sender, address(this))` rather than being
     *      encoded in the calldata, enabling a single static calldata entry to handle
     *      any claim amount.
     *
     *      Output tokens are sent directly to `msg.sender` (the Swapper) by the
     *      UniV3 router, so this adapter never holds the output token.
     *
     *      No access control is required: the adapter only consumes the allowance
     *      that `msg.sender` has explicitly granted to it, so no third party can
     *      exploit the call.
     *
     * @param tokenIn          Source token address (e.g. WETH).
     * @param tokenOut         Destination token address (e.g. USDC).
     * @param fee              Uniswap V3 pool fee tier (e.g. 3000 = 0.3%, 500 = 0.05%).
     * @param amountOutMinimum Minimum amount of tokenOut the router must return; reverts if not met.
     * @return amountOut Amount of tokenOut received by the Swapper.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOutMinimum
    )
        external
        returns (uint256 amountOut)
    {
        uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
        require(amountIn != 0, ZeroAllowance());

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: msg.sender,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = SWAP_ROUTER.exactInputSingle(params);

        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), 0);

        // slither-disable-next-line reentrancy-events
        emit AdapterSwapExecuted(tokenIn, tokenOut, fee, amountIn, amountOut);
    }
}
