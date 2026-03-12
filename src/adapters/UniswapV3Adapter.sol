// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IQuotableAdapter} from "../interfaces/IQuotableAdapter.sol";
import {IQuoterV2} from "../interfaces/IQuoterV2.sol";

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
 */
contract UniswapV3Adapter is Ownable2Step, IQuotableAdapter {
    /// @notice Uniswap V3 QuoterV2 contract address.
    IQuoterV2 public immutable QUOTER;

    /// @notice Default fee tier used when no pair-specific tier is configured (0.3%).
    uint24 public constant DEFAULT_FEE = 3000;

    /// @notice Per-pair fee tier overrides, keyed by keccak256(tokenIn, tokenOut).
    mapping(bytes32 pairKey => uint24 fee) public pairFees;

    /// @notice Thrown when a required address is zero.
    error ZeroAddress();

    /**
     * @notice Emitted when a per-pair fee tier is set or cleared.
     * @param tokenIn Source token address.
     * @param tokenOut Destination token address.
     * @param fee New fee tier in hundredths of a bip (e.g. 3000 = 0.3%). 0 resets to DEFAULT_FEE.
     */
    event PairFeeSet(address indexed tokenIn, address indexed tokenOut, uint24 fee);

    /**
     * @param quoter_ Address of the Uniswap V3 QuoterV2 contract.
     * @param owner_ Address receiving initial ownership.
     */
    constructor(address quoter_, address owner_) Ownable(owner_) {
        require(quoter_ != address(0) && owner_ != address(0), ZeroAddress());
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
