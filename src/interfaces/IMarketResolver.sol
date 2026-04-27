// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IMarketResolver {
    event MarketResolved(uint256 indexed marketId, uint256[] payouts);

    function resolve(uint256 marketId, uint256[] calldata payouts) external;

    function isMarketResolved(uint256 marketId) external view returns (bool);
}
