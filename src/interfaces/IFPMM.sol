// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFPMM — Interface for Gnosis Fixed Product Market Maker
/// @notice Subset of FPMM functions needed by the Vault for trading
interface IFPMM {
    function buy(uint256 investmentAmount, uint256 outcomeIndex, uint256 minOutcomeTokensToBuy) external;

    function sell(uint256 returnAmount, uint256 outcomeIndex, uint256 maxOutcomeTokensToSell) external;

    function conditionalTokens() external view returns (address);

    function collateralToken() external view returns (address);

    function conditionIds(uint256 index) external view returns (bytes32);
}
