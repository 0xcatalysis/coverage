// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IQuoterV2} from "../interfaces/IQuoterV2.sol";

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
 *      calldata encodes `swap(tokenIn, tokenOut, fee)` — all static per route. At execution
 *      time, the adapter dynamically resolves `amountIn` from the Swapper's ERC-20 approval.
 *
 *      Sepolia SwapRouter02: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
 *      Sepolia QuoterV2:     0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3
 *      Mainnet SwapRouter02: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
 *      Mainnet QuoterV2:     0x61fFE014bA17989E743c5F6cB21bF9697530B21e
 */
contract UniswapV3Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a swap is executed through the adapter.
    event AdapterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    /// @notice Reverts when called with a zero address.
    error ZeroAddress();

    /// @notice Reverts when the allowance read from the caller is zero.
    error ZeroAllowance();

    /// @notice Reverts when routeCalldata passed to quote() is too short to decode.
    error InvalidRouteCalldata();

    /// @notice Uniswap V3 SwapRouter02 address (immutable, set at construction).
    IV3SwapRouter public immutable SWAP_ROUTER;

    /// @notice Uniswap V3 QuoterV2 address (immutable, set at construction).
    IQuoterV2 public immutable QUOTER;

    /**
     * @notice Deploys the adapter pointing at specific SwapRouter02 and QuoterV2 instances.
     * @param swapRouter_ Uniswap V3 SwapRouter02 address.
     *                    Sepolia: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
     *                    Mainnet: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
     * @param quoter_     Uniswap V3 QuoterV2 address.
     *                    Sepolia: 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3
     *                    Mainnet: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
     */
    constructor(address swapRouter_, address quoter_) {
        require(swapRouter_ != address(0) && quoter_ != address(0), ZeroAddress());
        SWAP_ROUTER = IV3SwapRouter(swapRouter_);
        QUOTER = IQuoterV2(quoter_);
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
     * @param tokenIn  Source token address (e.g. WETH).
     * @param tokenOut Destination token address (e.g. USDC).
     * @param fee      Uniswap V3 pool fee tier (e.g. 3000 = 0.3%, 500 = 0.05%).
     * @return amountOut Amount of tokenOut received by the Swapper.
     */
    function swap(address tokenIn, address tokenOut, uint24 fee) external returns (uint256 amountOut) {
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
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amountOut = SWAP_ROUTER.exactInputSingle(params);

        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), 0);

        // slither-disable-next-line reentrancy-events
        emit AdapterSwapExecuted(tokenIn, tokenOut, fee, amountIn, amountOut);
    }

    /**
     * @inheritdoc ISwapAdapter
     * @notice Quotes the expected output for a swap without executing it.
     * @param routeCalldata The stored calldata for the route (ABI-encoded swap selector + params).
     * @param amountIn Amount of tokenIn to quote for.
     * @return amountOut Expected amount of tokenOut.
     */
    function quote(bytes calldata routeCalldata, uint256 amountIn) external override returns (uint256 amountOut) {
        // routeCalldata = selector (4 bytes) + abi.encode(address tokenIn, address tokenOut, uint24 fee)
        require(routeCalldata.length >= 4 + 96, InvalidRouteCalldata());
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(routeCalldata[4:], (address, address, uint24));

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
        });

        // slither-disable-next-line unused-return
        (amountOut,,,) = QUOTER.quoteExactInputSingle(params);
    }
}
