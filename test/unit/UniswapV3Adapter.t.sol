// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {UniswapV3Adapter} from "../../src/swappers/UniswapV3Adapter.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @notice Mock Uniswap V3 SwapRouter02 that records received params and returns a preset output.
 * @dev Pulls tokenIn from the adapter (via allowance) and pushes tokenOut to recipient.
 */
contract MockSwapRouter {
    uint256 public lastAmountOutMinimum;
    address public lastRecipient;
    address public lastTokenIn;
    address public lastTokenOut;
    uint24 public lastFee;
    uint256 public lastAmountIn;

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
        lastRecipient = params.recipient;
        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastFee = params.fee;
        lastAmountIn = params.amountIn;

        require(_outputAmount >= params.amountOutMinimum, "MockSwapRouter: insufficient output");

        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(params.tokenOut).transfer(params.recipient, _outputAmount);

        return _outputAmount;
    }
}

// ---------------------------------------------------------------------------
// Unit test suite
// ---------------------------------------------------------------------------

contract UniswapV3AdapterTest is Test {
    UniswapV3Adapter internal adapter;
    MockSwapRouter internal router;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal swapper;
    uint24 internal constant FEE = 3000;

    event AdapterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    function setUp() public {
        swapper = makeAddr("swapper");

        router = new MockSwapRouter();
        tokenIn = new MockERC20("Token In", "TIN");
        tokenOut = new MockERC20("Token Out", "TOUT");

        adapter = new UniswapV3Adapter(address(router), swapper);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_WhenRouterZero_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(0), swapper);
    }

    function test_constructor_WhenSwapperZero_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(router), address(0));
    }

    function test_constructor_SetsSwapRouter() public view {
        assertEq(address(adapter.SWAP_ROUTER()), address(router), "SWAP_ROUTER mismatch");
    }

    function test_constructor_SetsSwapper() public view {
        assertEq(adapter.SWAPPER(), swapper, "SWAPPER mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                               SWAP
    //////////////////////////////////////////////////////////////*/

    function test_swap_WhenCallerIsNotSwapper_Reverts() public {
        address notSwapper = makeAddr("notSwapper");
        vm.expectRevert(UniswapV3Adapter.UnauthorizedCaller.selector);
        vm.prank(notSwapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);
    }

    function test_swap_WhenZeroAllowance_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAllowance.selector);
        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);
    }

    function test_swap_WhenAmountOutMinimumExceedsRouterOutput_Reverts() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 90 ether;
        uint256 minimumRequired = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.expectRevert("MockSwapRouter: insufficient output");
        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, minimumRequired);
    }

    function test_swap_WhenZeroAmountOutMinimum_ForwardsToRouter() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        uint256 amountOut = adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);

        assertEq(amountOut, routerOutput, "amountOut mismatch");
        assertEq(router.lastAmountOutMinimum(), 0, "amountOutMinimum must be forwarded as 0");
    }

    function test_swap_WhenNonZeroAmountOutMinimum_ForwardsToRouter() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;
        uint256 minimumRequired = 90 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        uint256 amountOut = adapter.swap(address(tokenIn), address(tokenOut), FEE, minimumRequired);

        assertEq(amountOut, routerOutput, "amountOut mismatch");
        assertEq(router.lastAmountOutMinimum(), minimumRequired, "amountOutMinimum not forwarded correctly");
    }

    function test_swap_WhenAmountOutMinimumEqualToOutput_Succeeds() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        uint256 amountOut = adapter.swap(address(tokenIn), address(tokenOut), FEE, routerOutput);

        assertEq(amountOut, routerOutput, "amountOut mismatch");
        assertEq(router.lastAmountOutMinimum(), routerOutput, "amountOutMinimum must equal routerOutput");
    }

    function test_swap_TransfersTokenInFromSwapper() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);

        assertEq(tokenIn.balanceOf(swapper), 0, "swapper should have sent all tokenIn");
        assertEq(tokenIn.balanceOf(address(adapter)), 0, "adapter should not hold tokenIn");
        assertEq(tokenIn.balanceOf(address(router)), amountIn, "router should have received tokenIn");
    }

    function test_swap_SendsTokenOutToSwapper() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);

        assertEq(tokenOut.balanceOf(swapper), routerOutput, "swapper should receive tokenOut from router");
        assertEq(tokenOut.balanceOf(address(adapter)), 0, "adapter should not hold tokenOut");
    }

    function test_swap_ClearsRouterApprovalAfterSwap() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);

        assertEq(tokenIn.allowance(address(adapter), address(router)), 0, "Router approval must be cleared after swap");
    }

    function test_swap_ForwardsCorrectParamsToRouter() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;
        uint24 fee = 500;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), fee, 0);

        assertEq(router.lastTokenIn(), address(tokenIn), "tokenIn mismatch");
        assertEq(router.lastTokenOut(), address(tokenOut), "tokenOut mismatch");
        assertEq(router.lastFee(), fee, "fee mismatch");
        assertEq(router.lastAmountIn(), amountIn, "amountIn mismatch");
        assertEq(router.lastRecipient(), swapper, "recipient must be msg.sender (swapper)");
    }

    function test_swap_EmitsAdapterSwapExecuted() public {
        uint256 amountIn = 100 ether;
        uint256 routerOutput = 95 ether;

        tokenIn.mint(swapper, amountIn);
        tokenOut.mint(address(router), routerOutput);
        router.setOutputAmount(routerOutput);

        vm.prank(swapper);
        tokenIn.approve(address(adapter), amountIn);

        vm.expectEmit(true, true, false, true, address(adapter));
        emit AdapterSwapExecuted(address(tokenIn), address(tokenOut), FEE, amountIn, routerOutput);

        vm.prank(swapper);
        adapter.swap(address(tokenIn), address(tokenOut), FEE, 0);
    }
}
