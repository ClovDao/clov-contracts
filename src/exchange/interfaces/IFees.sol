// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

interface IFeesEE {
    error FeeTooHigh();

    /// @notice Emitted when a fee is charged
    event FeeCharged(address indexed receiver, uint256 tokenId, uint256 amount);

    /// @notice Emitted when a market fee rate is set
    event MarketFeeRateSet(bytes32 indexed conditionId, uint256 feeRateBps);

    /// @notice Emitted when the default fee rate is set
    event DefaultFeeRateSet(uint256 feeRateBps);

    error BatchTooLarge();
}

abstract contract IFees is IFeesEE {
    function getMaxFeeRate() public pure virtual returns (uint256);
    function getMarketFeeRate(bytes32 conditionId) public view virtual returns (uint256);
    function getDefaultFeeRate() public view virtual returns (uint256);
}
