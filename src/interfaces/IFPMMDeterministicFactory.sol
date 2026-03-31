// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IConditionalTokens } from "./IConditionalTokens.sol";

/// @title IFPMMDeterministicFactory — Minimal interface for Gnosis FPMM Deterministic Factory
/// @notice Only includes functions called by MarketFactory
interface IFPMMDeterministicFactory {
    function create2FixedProductMarketMaker(
        IConditionalTokens conditionalTokens,
        IERC20 collateralToken,
        bytes32[] calldata conditionIds,
        uint256 fee,
        uint256 initialFunds,
        uint256[] calldata distributionHint
    ) external returns (address);
}
