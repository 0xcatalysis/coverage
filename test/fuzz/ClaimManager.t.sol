// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {ClaimManager} from "../../src/ClaimManager.sol";
import {IClaimManager} from "../../src/interfaces/IClaimManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract FuzzToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FuzzSpec {
    bool private _payable;

    function setPayable(bool value) external {
        _payable = value;
    }

    function evaluate(ISpec.EvaluationContext calldata) external view returns (ISpec.EvaluationResult memory) {
        return ISpec.EvaluationResult({isPayable: _payable, notesHash: bytes32(0)});
    }
}

contract FuzzSpecRegistry {
    address private _spec;

    constructor(address spec) {
        _spec = spec;
    }

    function resolveSpec(address, bytes32) external view returns (ISpec) {
        return ISpec(_spec);
    }
}

import {ISlashingManager} from "../../src/interfaces/ISlashingManager.sol";

contract FuzzSlashingManager {
    address[] private _assets;
    uint256[] private _amounts;
    address private _token;

    function configure(address token, uint256 amount) external {
        _token = token;
        _assets = new address[](1);
        _assets[0] = token;
        _amounts = new uint256[](1);
        _amounts[0] = amount;
    }

    function previewSlashing(
        uint96,
        address
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        uint256 len = _assets.length < _amounts.length ? _assets.length : _amounts.length;
        vaults = new address[](len);
        tokens = new address[](len);
        tokenStakes = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            vaults[i] = address(uint160(i + 1));
            tokens[i] = _assets[i];
            tokenStakes[i] = _amounts[i];
        }
    }

    function executeSlashing(
        uint96,
        address,
        ISlashingManager.VaultSlash[] memory,
        bytes32
    )
        external
        returns (address[] memory, uint256[] memory)
    {
        if (_token != address(0)) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            FuzzToken(_token).transfer(msg.sender, FuzzToken(_token).balanceOf(address(this)));
        }
        return (_assets, _amounts);
    }
}

contract FuzzSwapper {
    uint256 private _output;
    address private _outToken;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function configure(address outToken, uint256 output) external {
        _outToken = outToken;
        _output = output;
    }

    function quoteSwap(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn;
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        FuzzToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        if (_outToken != address(0)) {
            FuzzToken(_outToken).mint(params.recipient, _output);
        }
        return _output;
    }
}

/// @dev 1:1 Chainlink feed mock for fuzz tests. All tokens have a feed; getUSDValue and getTokenAmount are 1:1.
contract FuzzChainlinkPriceFeed {
    function hasPriceFeed(address) external pure returns (bool) {
        return true;
    }

    function getUSDValue(address, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function getTokenAmount(address, uint256 usdValue) external pure returns (uint256) {
        return usdValue;
    }
}

contract FuzzPolicy {
    mapping(uint256 => IPolicyManager.PolicyMetadata) private _metadata;

    function set(uint96 id, IPolicyManager.PolicyMetadata memory m) external {
        _metadata[id] = m;
    }

    function policyMetadata(uint96 id) external view returns (IPolicyManager.PolicyMetadata memory) {
        return _metadata[id];
    }
}

contract FuzzCoverPool {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}

// ---------------------------------------------------------------------------
// Fuzz suite
// ---------------------------------------------------------------------------

contract ClaimManagerFuzzTest is Test {
    ClaimManager internal claimManager;
    FuzzSpec internal spec;
    FuzzSpecRegistry internal specRegistry;
    FuzzSlashingManager internal slashingMgr;
    FuzzSwapper internal swapper;
    FuzzPolicy internal policyContract;
    FuzzCoverPool internal pool;
    FuzzToken internal collateralToken;
    FuzzToken internal payoutToken;
    FuzzChainlinkPriceFeed internal chainlinkFeed;

    address internal admin = makeAddr("admin");
    address internal claimer = makeAddr("claimer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal operator = makeAddr("operator");

    uint96 internal constant POLICY_ID = 1;
    uint32 internal constant START = 1_000_000;
    uint32 internal constant MATURITY = START + 30 days;

    function setUp() public {
        spec = new FuzzSpec();
        specRegistry = new FuzzSpecRegistry(address(spec));
        slashingMgr = new FuzzSlashingManager();
        swapper = new FuzzSwapper();
        policyContract = new FuzzPolicy();
        pool = new FuzzCoverPool(operator);
        collateralToken = new FuzzToken("Collateral", "COL");
        payoutToken = new FuzzToken("Payout", "PAY");
        chainlinkFeed = new FuzzChainlinkPriceFeed();

        ClaimManager impl = new ClaimManager();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    ClaimManager.initialize,
                    (admin, address(specRegistry), address(slashingMgr), address(swapper), address(policyContract))
                )
            )
        );
        claimManager = ClaimManager(payable(proxy));
        claimManager.initializeV2(address(chainlinkFeed), 300);

        vm.warp(START);
        _setupPolicy(COVERAGE_LIMIT());
    }

    function COVERAGE_LIMIT() internal pure returns (uint256) {
        return 1000 ether;
    }

    function _setupPolicy(uint256 coverageLimit) internal {
        policyContract.set(
            POLICY_ID,
            IPolicyManager.PolicyMetadata({
                buyer: makeAddr("buyer"),
                policyId: POLICY_ID,
                beneficiary: beneficiary,
                claimer: claimer,
                startTime: START,
                maturityTime: MATURITY,
                payoutToken: address(payoutToken),
                pool: address(pool),
                coverageLimit: coverageLimit,
                specId: keccak256("spec"),
                termsHash: keccak256("terms"),
                policyCommit: keccak256("commit"),
                premiumDefaulted: false,
                curator: operator
            })
        );
    }

    // ------------------------------------------------------------------
    // Fuzz: requestedAmount never exceeds coverage limit
    // ------------------------------------------------------------------
    function testFuzz_fileClaim_RequestedAmountBounded(uint256 coverageLimit, uint256 requestedAmount) public {
        coverageLimit = bound(coverageLimit, 1, 1_000_000 ether);
        requestedAmount = bound(requestedAmount, 1, coverageLimit);

        _setupPolicy(coverageLimit);
        spec.setPayable(true);

        collateralToken.mint(address(slashingMgr), requestedAmount);
        slashingMgr.configure(address(collateralToken), requestedAmount);
        swapper.configure(address(payoutToken), requestedAmount);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, keccak256("evidence"), "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertLe(record.payoutAmount, requestedAmount, "Payout must not exceed requested amount");
        assertLe(record.payoutAmount, coverageLimit, "Payout must not exceed coverage limit");
    }

    // ------------------------------------------------------------------
    // Fuzz: remaining coverage monotonically decreases across two claims
    // ------------------------------------------------------------------
    function testFuzz_fileClaim_RemainingCoverageDecreases(uint256 amount1, uint256 amount2) public {
        uint256 limit = COVERAGE_LIMIT();
        amount1 = bound(amount1, 1, limit / 2);
        amount2 = bound(amount2, 1, limit - amount1);

        spec.setPayable(true);

        uint256 totalNeeded = amount1 + amount2;
        payoutToken.mint(address(slashingMgr), totalNeeded);

        slashingMgr.configure(address(payoutToken), amount1);

        uint256 remainingBefore = claimManager.remainingCoverage(POLICY_ID);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, amount1, keccak256("ev1"), "");

        uint256 remainingMid = claimManager.remainingCoverage(POLICY_ID);
        assertLt(remainingMid, remainingBefore, "Remaining should decrease after first claim");

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        payoutToken.mint(address(slashingMgr), amount2);
        slashingMgr.configure(address(payoutToken), amount2);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, amount2, keccak256("ev2"), "");

        uint256 remainingAfter = claimManager.remainingCoverage(POLICY_ID);
        assertLt(remainingAfter, remainingMid, "Remaining should decrease after second claim");
        assertLe(remainingBefore - remainingAfter, limit, "Total paid must not exceed coverage limit");
    }

    // ------------------------------------------------------------------
    // Fuzz: claim outside time window always reverts
    // ------------------------------------------------------------------
    function testFuzz_fileClaim_OutsideTimeWindow_Reverts(uint32 warpTime) public {
        bool before = (warpTime % 2 == 0);
        if (before) {
            uint32 t = uint32(bound(warpTime, 0, START - 1));
            vm.warp(t);
        } else {
            uint32 t = uint32(bound(warpTime, MATURITY + 1, type(uint32).max));
            vm.warp(t);
        }

        vm.expectRevert();
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 1 ether, keccak256("evidence"), "");
    }

    // ------------------------------------------------------------------
    // Fuzz: setMaxSwapSlippageBps only accepts values <= 3_000
    // ------------------------------------------------------------------
    function testFuzz_setMaxSwapSlippageBps_ValidRange(uint16 bps) public {
        if (bps > 3000) {
            vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidSlippageBps.selector, bps));
            vm.prank(admin);
            claimManager.setMaxSwapSlippageBps(bps);
        } else {
            vm.prank(admin);
            claimManager.setMaxSwapSlippageBps(bps);
            assertEq(claimManager.maxSwapSlippageBps(), bps);
        }
    }
}
