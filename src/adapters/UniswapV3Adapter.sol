// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuotableAdapter} from "../interfaces/IQuotableAdapter.sol";
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
 * @notice Bridges the Swapper's static-calldata swap pattern to Uniswap V3 SwapRouter02
 *         and implements IQuotableAdapter for DEX-based quoting via QuoterV2.
 * @dev Deployed as the `swapTarget` for Swapper routes where collateral must be converted
 *      to the payout token via Uniswap V3. The `quote` function is called by Swapper.quoteSwap
 *      to obtain token-native estimates used in ClaimManager._computeVaultSlashes.
 *
 *      The fee tier used for quoting is stored per token pair and defaults to 0.3% (3000).
 *      Set fee to 0 to revert a pair back to the default.
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
 *      Sepolia SwapRouter02: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
 */
contract UniswapV3Adapter is Ownable2Step, IQuotableAdapter {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V3 SwapRouter02 address (immutable, set at construction).
    IV3SwapRouter public immutable SWAP_ROUTER;

    /// @notice Authorized Swapper address; the only caller permitted to invoke `swap()`.
    address public immutable SWAPPER;

    /// @notice Uniswap V3 QuoterV2 contract address.
    IQuoterV2 public immutable QUOTER;

    /// @notice Default fee tier used when no pair-specific tier is configured (0.3%).
    uint24 public constant DEFAULT_FEE = 3000;

    /// @notice Per-pair fee tier overrides, keyed by keccak256(tokenIn, tokenOut).
    mapping(bytes32 pairKey => uint24 fee) public pairFees;

    /// @notice Emitted when a swap is executed through the adapter.
    event AdapterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    /**
     * @notice Emitted when a per-pair fee tier is set or cleared.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param fee New fee tier in hundredths of a bip (e.g. 3000 = 0.3%). 0 resets to DEFAULT_FEE.
     */
    event PairFeeSet(address indexed tokenIn, address indexed tokenOut, uint24 fee);

    /// @notice Thrown when a required address is zero.
    error ZeroAddress();

    /// @notice Thrown when the allowance read from the caller is zero.
    error ZeroAllowance();

    /// @notice Thrown when called by any address other than the authorized Swapper.
    error UnauthorizedCaller();

    /**
     * @param swapRouter_ Uniswap V3 SwapRouter02 address.
     *                    Sepolia: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
     *                    Mainnet: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
     * @param swapper_    Swapper contract address; the only caller authorized to invoke `swap()`.
     * @param quoter_     Address of the Uniswap V3 QuoterV2 contract.
     * @param owner_      Address receiving initial ownership.
     */
    constructor(address swapRouter_, address swapper_, address quoter_, address owner_) Ownable(owner_) {
        require(swapRouter_ != address(0) && swapper_ != address(0) && quoter_ != address(0), ZeroAddress());
        SWAP_ROUTER = IV3SwapRouter(swapRouter_);
        SWAPPER = swapper_;
        QUOTER = IQuoterV2(quoter_);
    }

    /**
     * @notice Sets the Uniswap V3 fee tier used when quoting a specific token pair.
     * @dev Pass fee = 0 to clear an override and revert to DEFAULT_FEE (3000).
     *      Valid Uniswap V3 tiers are 100, 500, 3000, and 10000.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param fee Fee tier in hundredths of a bip (e.g. 500 = 0.05%, 3000 = 0.3%, 10000 = 1%).
     */
    function setPairFee(address tokenIn, address tokenOut, uint24 fee) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(tokenIn, tokenOut));
        pairFees[key] = fee;
        emit PairFeeSet(tokenIn, tokenOut, fee);
    }

    /**
     * @inheritdoc IQuotableAdapter
     * @dev Calls QuoterV2.quoteExactInputSingle. Not a view because QuoterV2 uses
     *      swap simulation with revert internally.
     */
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external override returns (uint256 amountOut) {
        uint24 fee = _getFee(tokenIn, tokenOut);
        // slither-disable-next-line unused-return
        (amountOut,,,) = QUOTER.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
            })
        );
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
     *      Only the authorized Swapper (stored as `SWAPPER`) may call this function.
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
     * @notice Returns the fee tier for a token pair, falling back to DEFAULT_FEE.
     */
    function _getFee(address tokenIn, address tokenOut) private view returns (uint24 fee) {
        bytes32 key = keccak256(abi.encodePacked(tokenIn, tokenOut));
        fee = pairFees[key];
        if (fee == 0) {
            fee = DEFAULT_FEE;
        }
    }
}
