// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {MockPolicyManager} from "./Mocks.sol";

/// @title ForkClaimManager
/// @notice Claim manager for fork tests that pays insurance from pre-funded USDC balance
///         rather than minting a MockERC20. This lets us test with real USDC as payout token.
///         Does NOT inherit IClaimManager (which extends IAccessControl) -- only implements
///         the two methods the adapter actually calls: fileClaim() and policyClaim().
contract ForkClaimManager {
    address public policyManager;
    IERC20 public immutable usdc;

    struct PolicyClaim {
        uint256 totalPaidOut;
        uint256 claimCount;
    }

    mapping(uint96 => PolicyClaim) private _policyClaims;

    constructor(address policyManager_, address usdc_) {
        policyManager = policyManager_;
        usdc = IERC20(usdc_);
    }

    function policyClaim(uint96 policyId) external view returns (PolicyClaim memory) {
        return _policyClaims[policyId];
    }

    function totalPaidOut(uint96 policyId) external view returns (uint256) {
        return _policyClaims[policyId].totalPaidOut;
    }

    function fileClaim(
        uint96 policyId,
        uint256 claimAmount,
        bytes32 evidenceHash,
        bytes memory additionalData
    )
        external
        returns (uint256)
    {
        IPolicyManager.PolicyMetadata memory meta = MockPolicyManager(policyManager).policyMetadata(policyId);

        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: policyId,
            pool: meta.pool,
            coverageLimit: meta.coverageLimit,
            startTime: meta.startTime,
            maturityTime: meta.maturityTime,
            evaluationTime: uint32(block.timestamp),
            evidenceHash: evidenceHash,
            additionalData: additionalData
        });

        ISpec spec = ISpec(meta.beneficiary);
        ISpec.EvaluationResult memory result = spec.evaluate(context);

        if (result.isPayable) {
            (, uint256 claimedAmount) = abi.decode(additionalData, (address, uint256));
            // Transfer pre-funded USDC to the adapter (beneficiary) as insurance payout
            usdc.transfer(meta.beneficiary, claimedAmount);
            _policyClaims[policyId].totalPaidOut += claimedAmount;
            _policyClaims[policyId].claimCount++;
        }

        return result.isPayable ? 1 : 0;
    }
}
