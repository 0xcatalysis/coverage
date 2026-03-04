// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {UniswapV3Adapter} from "../../src/swappers/UniswapV3Adapter.sol";
import {IQuoterV2} from "../../src/interfaces/IQuoterV2.sol";
import {IQuotableAdapter} from "../../src/interfaces/IQuotableAdapter.sol";

contract UniswapV3AdapterTest is Test {
    address internal swapRouter;
    address internal tokenIn;
    address internal tokenOut;
    uint24 internal constant FEE = 3000;

    UniswapV3Adapter internal adapter;
    MockSwapRouter internal mockSwapRouter;
    MockQuoterV2 internal mockQuoter;
    MockToken internal mockTokenIn;
    MockToken internal mockTokenOut;

    event AdapterSwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        mockSwapRouter = new MockSwapRouter();
        mockQuoter = new MockQuoterV2();
        mockTokenIn = new MockToken("Token In", "TIN");
        mockTokenOut = new MockToken("Token Out", "TOUT");

        swapRouter = address(mockSwapRouter);
        tokenIn = address(mockTokenIn);
        tokenOut = address(mockTokenOut);

        adapter = new UniswapV3Adapter(swapRouter, address(mockQuoter));

        vm.label(swapRouter, "MockSwapRouter");
        vm.label(address(mockQuoter), "MockQuoterV2");
        vm.label(tokenIn, "TokenIn");
        vm.label(tokenOut, "TokenOut");
        vm.label(address(adapter), "UniswapV3Adapter");
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_SetsSwapRouter() public view {
        assertEq(address(adapter.SWAP_ROUTER()), swapRouter, "SWAP_ROUTER mismatch");
    }

    function test_constructor_SetsQuoter() public view {
        assertEq(address(adapter.QUOTER()), address(mockQuoter), "QUOTER mismatch");
    }

    function test_constructor_ZeroSwapRouter_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(0), address(mockQuoter));
    }

    function test_constructor_ZeroQuoter_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(swapRouter, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAP
    //////////////////////////////////////////////////////////////*/

    function test_swap_ExecutesSwapAndReturnsAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedOut = 2000e6;
        mockSwapRouter.setAmountOut(expectedOut);
        mockTokenIn.mint(address(this), amountIn);
        mockTokenIn.approve(address(adapter), amountIn);

        uint256 amountOut = adapter.swap(tokenIn, tokenOut, FEE);

        assertEq(amountOut, expectedOut, "amountOut mismatch");
    }

    function test_swap_EmitsAdapterSwapExecuted() public {
        uint256 amountIn = 1 ether;
        uint256 expectedOut = 2000e6;
        mockSwapRouter.setAmountOut(expectedOut);
        mockTokenIn.mint(address(this), amountIn);
        mockTokenIn.approve(address(adapter), amountIn);

        vm.expectEmit(true, true, false, true);
        emit AdapterSwapExecuted(tokenIn, tokenOut, FEE, amountIn, expectedOut);

        adapter.swap(tokenIn, tokenOut, FEE);
    }

    function test_swap_ZeroAllowance_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAllowance.selector);
        adapter.swap(tokenIn, tokenOut, FEE);
    }

    /*//////////////////////////////////////////////////////////////
                                 QUOTE
    //////////////////////////////////////////////////////////////*/

    function _buildRouteCalldata(address _tokenIn, address _tokenOut, uint24 fee) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("swap(address,address,uint24)", _tokenIn, _tokenOut, fee);
    }

    function test_quote_ReturnsExpectedAmountOut() public {
        uint256 amountIn = 1 ether;
        uint256 expectedOut = 1900e6;
        mockQuoter.setAmountOut(expectedOut);

        bytes memory routeCalldata = _buildRouteCalldata(tokenIn, tokenOut, FEE);
        uint256 amountOut = adapter.quote(routeCalldata, amountIn);

        assertEq(amountOut, expectedOut, "Quote amountOut mismatch");
    }

    function test_quote_PassesCorrectParamsToQuoter() public {
        uint256 amountIn = 500e6;
        uint256 expectedOut = 0.24 ether;
        mockQuoter.setAmountOut(expectedOut);

        bytes memory routeCalldata = _buildRouteCalldata(tokenIn, tokenOut, FEE);
        adapter.quote(routeCalldata, amountIn);

        assertEq(mockQuoter.lastTokenIn(), tokenIn, "tokenIn mismatch");
        assertEq(mockQuoter.lastTokenOut(), tokenOut, "tokenOut mismatch");
        assertEq(mockQuoter.lastAmountIn(), amountIn, "amountIn mismatch");
        assertEq(mockQuoter.lastFee(), FEE, "fee mismatch");
    }

    function test_quote_TooShortCalldata_Reverts() public {
        bytes memory shortCalldata = hex"aabbccdd";
        vm.expectRevert(UniswapV3Adapter.InvalidRouteCalldata.selector);
        adapter.quote(shortCalldata, 1 ether);
    }

    function test_quote_AdapterImplementsIQuotableAdapter() public {
        uint256 amountIn = 1 ether;
        uint256 expectedOut = 1500e6;
        mockQuoter.setAmountOut(expectedOut);

        bytes memory routeCalldata = _buildRouteCalldata(tokenIn, tokenOut, FEE);
        uint256 amountOut = IQuotableAdapter(address(adapter)).quote(routeCalldata, amountIn);
        assertEq(amountOut, expectedOut, "IQuotableAdapter.quote should delegate to adapter");
    }

    function test_quote_DifferentFeeTiers() public {
        uint24[] memory feeTiers = new uint24[](3);
        feeTiers[0] = 500;
        feeTiers[1] = 3000;
        feeTiers[2] = 10_000;

        uint256 amountIn = 1 ether;
        mockQuoter.setAmountOut(1800e6);

        for (uint256 i = 0; i < feeTiers.length; i++) {
            bytes memory routeCalldata = _buildRouteCalldata(tokenIn, tokenOut, feeTiers[i]);
            adapter.quote(routeCalldata, amountIn);
            assertEq(mockQuoter.lastFee(), feeTiers[i], "Fee tier not passed correctly");
        }
    }
}

/*//////////////////////////////////////////////////////////////
                         MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSwapRouter {
    uint256 private _amountOut;

    function setAmountOut(uint256 amountOut_) external {
        _amountOut = amountOut_;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256) {
        if (_amountOut > 0 && params.recipient != address(0)) {
            MockToken(params.tokenOut).mint(params.recipient, _amountOut);
        }
        return _amountOut;
    }
}

contract MockQuoterV2 {
    uint256 private _amountOut;
    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint24 public lastFee;

    function setAmountOut(uint256 amountOut_) external {
        _amountOut = amountOut_;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastAmountIn = params.amountIn;
        lastFee = params.fee;
        return (_amountOut, 0, 0, 0);
    }
}
