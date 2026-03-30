// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuotableAdapter} from "../interfaces/IQuotableAdapter.sol";
import {IQuoterV2} from "../interfaces/IQuoterV2.sol";

/**
 * @notice Minimal Uniswap V3 SwapRouter02 interface.
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
 *      calldata encodes `swap(tokenIn, tokenOut, fee, amountOutMinimum)` — all static per route.
 *      At execution time, the adapter dynamically resolves `amountIn` from the Swapper's ERC-20 approval.
 *
 *      Also implements `IQuotableAdapter.quote` via QuoterV2 for slippage-free pre-swap price estimation
 *      used by ClaimManager._computeVaultSlashes and _processCollateral.
 *
 *      Deployment: deployed separately from the main Coverage suite; configured via
 *      Swapper.setSwapTargetWhitelist() and Swapper.setSwapRoute() by SWAP_MANAGER_ROLE.
 *
 *      Sepolia SwapRouter02: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
 *      Mainnet SwapRouter02: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
 *      Sepolia QuoterV2:     0xEd1f6473345F45b75833fd55D191EBE6d13fB0cB
 *      Mainnet QuoterV2:     0x61fFE014bA17989E743c5F6cB21bF9697530B21e
 */
contract UniswapV3Adapter is IQuotableAdapter {
    using SafeERC20 for IERC20;

    event AdapterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    error ZeroAddress();
    error ZeroAllowance();
    error UnauthorizedCaller();

    IV3SwapRouter public immutable SWAP_ROUTER;
    IQuoterV2 public immutable QUOTER;
    address public immutable SWAPPER;

    constructor(address swapRouter_, address quoter_, address swapper_) {
        require(swapRouter_ != address(0) && quoter_ != address(0) && swapper_ != address(0), ZeroAddress());
        SWAP_ROUTER = IV3SwapRouter(swapRouter_);
        QUOTER = IQuoterV2(quoter_);
        SWAPPER = swapper_;
    }

    /**
     * @notice Executes a single-hop Uniswap V3 swap on behalf of the Swapper.
     * @dev `amountIn` is resolved dynamically from `allowance(msg.sender, address(this))`.
     *      Only the authorized Swapper may call this function.
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
        require(msg.sender == SWAPPER, UnauthorizedCaller());

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

    /**
     * @inheritdoc IQuotableAdapter
     * @dev Decodes (tokenIn, tokenOut, fee) from the stored swapCalldata (skipping 4-byte selector),
     *      then calls QuoterV2.quoteExactInputSingle. Returns 0 on any revert.
     */
    function quote(uint256 amountIn, bytes calldata swapCalldata) external override returns (uint256 amountOut) {
        // swapCalldata = selector(4) + tokenIn(32) + tokenOut(32) + fee(32) + amountOutMinimum(32)
        if (swapCalldata.length < 100) return 0;
        (address tokenIn, address tokenOut, uint24 fee,) =
            abi.decode(swapCalldata[4:], (address, address, uint24, uint256));

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
        });

        // slither-disable-next-line unused-return
        try QUOTER.quoteExactInputSingle(params) returns (uint256 out, uint160, uint32, uint256) {
            return out;
        } catch {
            return 0;
        }
    }
}
