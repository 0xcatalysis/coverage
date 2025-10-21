// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";

contract CoverPoolFuzzTest is Test {
    function testFuzz_deployMultipleCoverPools(uint8 count) public {
        uint8 deployCount = uint8(bound(count, 1, 25));

        for (uint8 i = 0; i < deployCount; i++) {
            CoverPool coverPool = new CoverPool();
            assertGt(address(coverPool).code.length, 0, "CoverPool should have runtime code");
        }
    }
}
