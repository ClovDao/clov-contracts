// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IConditionalTokens — Minimal interface for Gnosis Conditional Tokens
/// @notice Only includes functions called by MarketFactory
interface IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}
