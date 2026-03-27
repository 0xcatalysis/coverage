// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract FuzzERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FuzzSwapRouter {
    uint256 public lastAmountOutMinimum;

    uint256 private _outputAmount;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function setOutputAmount(uint256 amount) external {
        _outputAmount = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        lastAmountOutMinimum = params.amountOutMinimum;

        require(_outputAmount >= params.amountOutMinimum, "FuzzSwapRouter: insufficient output");

        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        FuzzERC20(params.tokenOut).transfer(params.recipient, _outputAmount);

        return _outputAmount;
    }
}

// ---------------------------------------------------------------------------
// Fuzz suite
// ---------------------------------------------------------------------------

/**
 * @notice Minimal stub for IQuoterV2 used in fuzz tests; always returns zero.
 */
contract FuzzQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata)
        external
        pure
        returns (uint256, uint160, uint32, uint256)
    {
        return (0, 0, 0, 0);
    }
}

contract UniswapV3AdapterFuzzTest is Test {
    UniswapV3Adapter internal adapter;
    FuzzSwapRouter internal router;
    FuzzQuoterV2 internal quoter;
    FuzzERC20 internal tokenIn;
    FuzzERC20 internal tokenOut;

    address internal swapper;
    address internal owner;
    uint24 internal constant FEE = 3000;

    function setUp() public {
        swapper = makeAddr("swapper");
        owner = makeAddr("owner");

        router = new FuzzSwapRouter();
        quoter = new FuzzQuoterV2();
        tokenIn = new FuzzERC20("Token In", "TIN");
        tokenOut = new FuzzERC20("Token Out", "TOUT");

        adapter = new UniswapV3Adapter(address(router), swapper, address(quoter), owner);
    }

    function testFuzz_swap_ForwardsAmountOutMinimum(uint256 amountIn, uint256 routerOutput, uint256 minimum) public {
        amountIn = bound(amountIn, 1, type(uint128).max);
        routerOutput = bound(routerOutput, 1, type(uint128).max);
        minimum = bound(minimum, 0, routerOutput);

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        uint256 amountOut = adapter.swap(address(tokenIn), address(tokenOut), FEE, minimum);

        assertEq(amountOut, routerOutput, "amountOut mismatch");
        assertEq(router.lastAmountOutMinimum(), minimum, "amountOutMinimum not forwarded");
    }

    function testFuzz_swap_WhenMinimumExceedsOutput_Reverts(
        uint256 amountIn,
        uint256 routerOutput,
        uint256 minimum
    )
        public
    {
        amountIn = bound(amountIn, 1, type(uint128).max);
        routerOutput = bound(routerOutput, 0, type(uint128).max - 1);
        minimum = bound(minimum, routerOutput + 1, type(uint128).max);

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.expectRevert("FuzzSwapRouter: insufficient output");
        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, minimum);
    }

    function testFuzz_swap_WhenZeroAllowance_Reverts(uint256 minimum) public {
        vm.expectRevert(UniswapV3Adapter.ZeroAllowance.selector);
        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, minimum);
    }

    function testFuzz_swap_WhenCallerIsNotSwapper_Reverts(address randomCaller) public {
        vm.assume(randomCaller != swapper);
        vm.expectRevert(UniswapV3Adapter.UnauthorizedCaller.selector);
        vm.prank(randomCaller);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);
    }
}
