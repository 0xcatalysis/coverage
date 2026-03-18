// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {IQuotableAdapter} from "../../src/interfaces/IQuotableAdapter.sol";
import {IQuoterV2} from "../../src/interfaces/IQuoterV2.sol";

contract UniswapV3AdapterTest is Test {
    address internal owner;
    address internal nonOwner;
    address internal tokenA;
    address internal tokenB;

    MockQuoterV2 internal mockQuoter;
    UniswapV3Adapter internal adapter;

    event PairFeeSet(address indexed tokenIn, address indexed tokenOut, uint24 fee);

    function setUp() public {
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");

        mockQuoter = new MockQuoterV2();
        adapter = new UniswapV3Adapter(address(mockQuoter), owner);

        vm.label(owner, "Owner");
        vm.label(nonOwner, "NonOwner");
        vm.label(tokenA, "TokenA");
        vm.label(tokenB, "TokenB");
        vm.label(address(mockQuoter), "MockQuoterV2");
        vm.label(address(adapter), "UniswapV3Adapter");
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_WhenQuoterZero_Reverts() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(0), owner);
    }

    function test_constructor_WhenOwnerZero_Reverts() public {
        // Ownable base constructor fires OwnableInvalidOwner before our ZeroAddress check
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new UniswapV3Adapter(address(mockQuoter), address(0));
    }

    function test_constructor_SetsQuoterAndOwner() public view {
        assertEq(address(adapter.QUOTER()), address(mockQuoter), "QUOTER mismatch");
        assertEq(adapter.owner(), owner, "Owner mismatch");
    }

    function test_constructor_SetsDefaultFee() public view {
        assertEq(adapter.DEFAULT_FEE(), 3000, "Default fee should be 3000 (0.3%)");
    }

    /*//////////////////////////////////////////////////////////////
                          SET PAIR FEE
    //////////////////////////////////////////////////////////////*/

    function test_setPairFee_WhenCallerNotOwner_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        adapter.setPairFee(tokenA, tokenB, 500);
    }

    function test_setPairFee_WhenValid_StoresFeeAndEmitsEvent() public {
        uint24 newFee = 500;

        vm.expectEmit(true, true, false, true, address(adapter));
        emit PairFeeSet(tokenA, tokenB, newFee);

        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, newFee);

        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        assertEq(adapter.pairFees(key), newFee, "Stored fee should match");
    }

    function test_setPairFee_WhenFeeZero_ClearsOverride() public {
        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, 10_000);

        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, 0);

        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        assertEq(adapter.pairFees(key), 0, "Fee should be cleared to zero");
    }

    function test_setPairFee_UpdatesExistingFee() public {
        vm.startPrank(owner);
        adapter.setPairFee(tokenA, tokenB, 500);
        adapter.setPairFee(tokenA, tokenB, 10_000);
        vm.stopPrank();

        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB));
        assertEq(adapter.pairFees(key), 10_000, "Fee should be updated to new value");
    }

    function test_setPairFee_DoesNotAffectReverseDirection() public {
        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, 500);

        bytes32 reverseKey = keccak256(abi.encodePacked(tokenB, tokenA));
        assertEq(adapter.pairFees(reverseKey), 0, "Reverse pair should not be affected");
    }

    /*//////////////////////////////////////////////////////////////
                              QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_quote_WhenNoOverride_UsesDefaultFee() public {
        uint256 amountIn = 100 ether;
        uint256 expectedOut = 98 ether;
        mockQuoter.setQuoteResult(expectedOut);

        uint256 result = adapter.quote(tokenA, tokenB, amountIn);

        assertEq(result, expectedOut, "Quote result mismatch");
        assertEq(mockQuoter.lastFeeUsed(), adapter.DEFAULT_FEE(), "Should use DEFAULT_FEE when no override");
    }

    function test_quote_WhenPairFeeOverrideSet_UsesOverrideFee() public {
        uint24 customFee = 100; // 0.01% tier
        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, customFee);

        uint256 amountIn = 100 ether;
        mockQuoter.setQuoteResult(99 ether);

        adapter.quote(tokenA, tokenB, amountIn);

        assertEq(mockQuoter.lastFeeUsed(), customFee, "Should use custom fee override");
    }

    function test_quote_WhenFeeOverrideIsZero_FallsBackToDefaultFee() public {
        // Set and then clear override
        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, 500);
        vm.prank(owner);
        adapter.setPairFee(tokenA, tokenB, 0); // clear to 0

        mockQuoter.setQuoteResult(98 ether);
        adapter.quote(tokenA, tokenB, 100 ether);

        assertEq(mockQuoter.lastFeeUsed(), adapter.DEFAULT_FEE(), "Cleared override should fall back to DEFAULT_FEE");
    }

    function test_quote_PassesCorrectParamsToQuoterV2() public {
        uint256 amountIn = 500 ether;
        mockQuoter.setQuoteResult(490 ether);

        adapter.quote(tokenA, tokenB, amountIn);

        assertEq(mockQuoter.lastTokenIn(), tokenA, "tokenIn mismatch");
        assertEq(mockQuoter.lastTokenOut(), tokenB, "tokenOut mismatch");
        assertEq(mockQuoter.lastAmountIn(), amountIn, "amountIn mismatch");
        assertEq(mockQuoter.lastSqrtPriceLimitX96(), 0, "sqrtPriceLimitX96 should be 0");
    }

    function test_quote_ImplementsIQuotableAdapter() public view {
        assertTrue(type(IQuotableAdapter).interfaceId != bytes4(0), "Interface ID should be non-zero");
        // Compile-time check: UniswapV3Adapter implements IQuotableAdapter
        IQuotableAdapter(address(adapter));
    }

    /*//////////////////////////////////////////////////////////////
                         OWNERSHIP (2-STEP)
    //////////////////////////////////////////////////////////////*/

    function test_ownership_TransferRequiresTwoSteps() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        adapter.transferOwnership(newOwner);

        assertEq(adapter.owner(), owner, "Owner should not change until accepted");
        assertEq(adapter.pendingOwner(), newOwner, "Pending owner should be set");

        vm.prank(newOwner);
        adapter.acceptOwnership();

        assertEq(adapter.owner(), newOwner, "Owner should change after acceptance");
    }
}

/*//////////////////////////////////////////////////////////////
                         MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockQuoterV2 is IQuoterV2 {
    uint256 private _result;

    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint24 public lastFeeUsed;
    uint160 public lastSqrtPriceLimitX96;

    function setQuoteResult(uint256 result_) external {
        _result = result_;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastAmountIn = params.amountIn;
        lastFeeUsed = params.fee;
        lastSqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        return (_result, 0, 0, 0);
    }
}
