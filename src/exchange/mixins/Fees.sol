// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { IFees } from "../interfaces/IFees.sol";

abstract contract Fees is IFees {
    /// @notice Maximum fee rate that can be signed into an Order
    uint256 internal constant MAX_FEE_RATE_BIPS = 200; // 200 bips or 2%

    /// @notice Default fee rate applied when no per-market rate is configured
    /// @dev Initialized to MAX_FEE_RATE_BIPS (200 bps / 2%). Admin can change via setDefaultFeeRate.
    uint256 internal _defaultFeeRate = MAX_FEE_RATE_BIPS;

    /// @notice Per-market fee rate in basis points (conditionId => feeRateBps)
    mapping(bytes32 => uint256) internal _marketFeeRates;

    function getMaxFeeRate() public pure override returns (uint256) {
        return MAX_FEE_RATE_BIPS;
    }

    function getDefaultFeeRate() public view override returns (uint256) {
        return _defaultFeeRate;
    }

    function getMarketFeeRate(bytes32 conditionId) public view override returns (uint256) {
        return _marketFeeRates[conditionId];
    }

    function _setDefaultFeeRate(uint256 feeRateBps) internal {
        if (feeRateBps > MAX_FEE_RATE_BIPS) revert FeeTooHigh();
        _defaultFeeRate = feeRateBps;
        emit DefaultFeeRateSet(feeRateBps);
    }

    function _setMarketFeeRate(bytes32 conditionId, uint256 feeRateBps) internal {
        if (feeRateBps > MAX_FEE_RATE_BIPS) revert FeeTooHigh();
        _marketFeeRates[conditionId] = feeRateBps;
        emit MarketFeeRateSet(conditionId, feeRateBps);
    }
}
