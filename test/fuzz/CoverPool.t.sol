// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract FuzzMockPolicyManager {
    uint96 public nextPolicyId;

    function bindPolicy(
        IPolicyManager.BindPolicyRequest calldata,
        ICoverPool.BoundPolicy calldata
    )
        external
        returns (uint96)
    {
        return ++nextPolicyId;
    }
}

// ---------------------------------------------------------------------------
// Fuzz suite
// ---------------------------------------------------------------------------

contract CoverPoolFuzzTest is Test {
    CoverPool internal implementation;
    CoverPool internal coverPool;
    FuzzMockPolicyManager internal mockPolicyManager;

    uint256 internal quoteSignerKey;
    address internal quoteSigner;
    address internal curator;
    address internal stakeManager;
    address internal specRegistry;

    function setUp() public {
        vm.warp(1_000_000);

        curator = makeAddr("curator");
        stakeManager = makeAddr("stakeManager");
        specRegistry = makeAddr("specRegistry");
        quoteSignerKey = uint256(keccak256("quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);

        mockPolicyManager = new FuzzMockPolicyManager();

        implementation = new CoverPool();
        address clone = Clones.clone(address(implementation));
        coverPool = CoverPool(clone);
        coverPool.initialize(curator, quoteSigner, address(mockPolicyManager), stakeManager, specRegistry, 125);
    }

    // ------------------------------------------------------------------
    // Fuzz: poolFeeBps initialisation bounds (max 2000 = 20%)
    // ------------------------------------------------------------------
    function testFuzz_initialize_PoolFeeBps(uint16 feeBps) public {
        address clone = Clones.clone(address(implementation));
        CoverPool pool = CoverPool(clone);

        if (feeBps > 2000) {
            vm.expectRevert();
        }
        pool.initialize(curator, quoteSigner, address(mockPolicyManager), stakeManager, specRegistry, feeBps);

        if (feeBps <= 2000) {
            assertEq(pool.poolFeeBps(), feeBps);
        }
    }

    // ------------------------------------------------------------------
    // Fuzz: setPoolFeeBps only callable by curator
    // ------------------------------------------------------------------
    function testFuzz_setPoolFeeBps_OnlyAdmin(address caller, uint16 feeBps) public {
        vm.assume(caller != curator);
        feeBps = uint16(bound(feeBps, 0, 9000));

        vm.expectRevert();
        vm.prank(caller);
        coverPool.setPoolFeeBps(feeBps);
    }
}
