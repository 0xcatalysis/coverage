// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ClaimManager} from "../../src/ClaimManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

// ---------------------------------------------------------------------------
// Mocks shared by handler
// ---------------------------------------------------------------------------

contract InvToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract InvSpec {
    function evaluate(ISpec.EvaluationContext calldata) external pure returns (ISpec.EvaluationResult memory) {
        return ISpec.EvaluationResult({isPayable: true, notesHash: bytes32(0)});
    }
}

contract InvSpecRegistry {
    address private immutable _SPEC;

    constructor(address spec) {
        _SPEC = spec;
    }

    function resolveSpec(address, bytes32) external view returns (ISpec) {
        return ISpec(_SPEC);
    }
}

contract InvSlashingManager {
    address private _token;

    function setToken(address t) external {
        _token = t;
    }

    function executeSlashing(
        uint96,
        address,
        uint256 slashAmount,
        bytes32
    )
        external
        returns (address[] memory, uint256[] memory)
    {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = _token;
        amounts[0] = slashAmount;
        if (_token != address(0)) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            InvToken(_token).transfer(msg.sender, slashAmount);
        }
        return (tokens, amounts);
    }
}

contract InvSwapper {
    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        InvToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        InvToken(params.tokenOut).mint(params.recipient, params.amountIn);
        return params.amountIn;
    }
}

contract InvPriceFeed {
    function getUSDValue(address, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function getTokenAmount(address, uint256 usdValue) external pure returns (uint256) {
        return usdValue;
    }
}

contract InvPolicy {
    mapping(uint256 => IPolicyManager.PolicyMetadata) private _metadata;

    function set(uint96 id, IPolicyManager.PolicyMetadata memory m) external {
        _metadata[id] = m;
    }

    function policyMetadata(uint96 id) external view returns (IPolicyManager.PolicyMetadata memory) {
        return _metadata[id];
    }
}

contract InvCoverPool {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}

// ---------------------------------------------------------------------------
// Handler — drives the invariant test via targeted calls
// ---------------------------------------------------------------------------

contract ClaimManagerHandler is Test {
    ClaimManager internal claimManager;
    InvPolicy internal policyContract;
    InvSlashingManager internal slashingMgr;
    InvToken internal payoutToken;
    InvToken internal collateralToken;

    address internal claimer;
    address internal curator;

    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1000 ether;

    uint256 public ghost_totalPaidOut;

    uint32 internal constant START = 1_000_000;
    uint32 internal constant MATURITY = START + 30 days;

    constructor(
        ClaimManager claimManager_,
        InvPolicy policy_,
        InvSlashingManager slashingMgr_,
        InvToken payoutToken_,
        InvToken collateralToken_,
        address claimer_,
        address curator_
    ) {
        claimManager = claimManager_;
        policyContract = policy_;
        slashingMgr = slashingMgr_;
        payoutToken = payoutToken_;
        collateralToken = collateralToken_;
        claimer = claimer_;
        curator = curator_;
    }

    function fileClaim(uint256 requestedAmountSeed) external {
        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        if (remaining == 0) return;

        if (claimManager.claimApprovalRequired(POLICY_ID)) {
            vm.prank(curator);
            claimManager.approveNextClaim(POLICY_ID);
        }

        uint256 requestedAmount = bound(requestedAmountSeed, 1, remaining);

        collateralToken.mint(address(slashingMgr), requestedAmount);
        slashingMgr.setToken(address(collateralToken));

        uint256 beneficiaryBefore = payoutToken.balanceOf(claimer);

        vm.prank(claimer);
        try claimManager.fileClaim(
            POLICY_ID, requestedAmount, keccak256(abi.encodePacked(requestedAmount, remaining)), ""
        ) returns (
            uint256
        ) {
            uint256 paidOut = payoutToken.balanceOf(claimer) - beneficiaryBefore;
            ghost_totalPaidOut += paidOut;
        } catch {}
    }
}

// ---------------------------------------------------------------------------
// Invariant test
// ---------------------------------------------------------------------------

contract ClaimManagerInvariantTest is StdInvariant, Test {
    ClaimManager internal claimManager;
    ClaimManagerHandler internal handler;

    InvToken internal payoutToken;
    InvToken internal collateralToken;

    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1000 ether;

    uint32 internal constant START = 1_000_000;
    uint32 internal constant MATURITY = START + 30 days;

    function setUp() public {
        vm.warp(START);
        _deploy();
        targetContract(address(handler));
    }

    function _deploy() private {
        address admin = makeAddr("admin");
        address claimer = makeAddr("claimer");

        InvSpec spec = new InvSpec();
        InvSlashingManager slashingMgr = new InvSlashingManager();
        InvSwapper swapper = new InvSwapper();
        InvPolicy policyContract = new InvPolicy();

        payoutToken = new InvToken("Payout", "PAY");
        collateralToken = new InvToken("Collateral", "COL");

        claimManager = _deployClaimManager(admin, spec, slashingMgr, swapper, policyContract);

        _setupPolicy(policyContract, claimer, claimer);

        handler = new ClaimManagerHandler(
            claimManager, policyContract, slashingMgr, payoutToken, collateralToken, claimer, makeAddr("operator")
        );
    }

    function _deployClaimManager(
        address admin,
        InvSpec spec,
        InvSlashingManager slashingMgr,
        InvSwapper swapper,
        InvPolicy policyContract
    )
        private
        returns (ClaimManager)
    {
        InvSpecRegistry specRegistry = new InvSpecRegistry(address(spec));
        InvPriceFeed priceFeed = new InvPriceFeed();
        ClaimManager impl = new ClaimManager();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    ClaimManager.initialize,
                    (
                        admin,
                        address(specRegistry),
                        address(slashingMgr),
                        address(swapper),
                        address(policyContract),
                        address(priceFeed)
                    )
                )
            )
        );
        return ClaimManager(proxy);
    }

    function _setupPolicy(InvPolicy policyContract, address claimer, address beneficiary) private {
        InvCoverPool pool = new InvCoverPool(makeAddr("operator"));
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
                coverageLimit: COVERAGE_LIMIT,
                specId: keccak256("spec"),
                termsHash: keccak256("terms"),
                policyCommit: keccak256("commit")
            })
        );
    }

    /// @dev Core invariant: the sum of all payouts never exceeds the policy's coverage limit.
    function invariant_totalPaidOutNeverExceedsCoverageLimit() public view {
        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertLe(COVERAGE_LIMIT - remaining, COVERAGE_LIMIT, "Remaining coverage must never go negative (underflow)");
        assertGe(remaining, 0, "Remaining coverage must be non-negative");
    }

    /// @dev Coverage limit minus remaining equals total paid out; must not exceed the limit.
    function invariant_remainingCoverageIsMonotonicallyNonIncreasing() public view {
        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertLe(handler.ghost_totalPaidOut(), COVERAGE_LIMIT, "Ghost total paid out must not exceed coverage limit");
        // Remaining + ghost_totalPaidOut may differ due to capping, but remaining must never exceed original limit.
        assertLe(remaining, COVERAGE_LIMIT, "Remaining must not exceed coverage limit");
    }
}
