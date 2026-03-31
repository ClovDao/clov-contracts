// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IClovOracleAdapter {
    struct Assertion {
        uint256 marketId;
        bytes32 assertionId;
        address asserter;
        bool outcome;
        bool settled;
        bool resolved;
    }

    event OutcomeAsserted(
        uint256 indexed marketId,
        bytes32 indexed assertionId,
        address indexed asserter,
        bool outcome
    );

    event OutcomeConfirmed(uint256 indexed marketId, bytes32 indexed assertionId, bool outcome);

    event AssertionDisputed(uint256 indexed marketId, bytes32 indexed assertionId);

    function assertOutcome(uint256 marketId, bool outcome, address asserter)
        external
        returns (bytes32 assertionId);

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    function assertionDisputedCallback(bytes32 assertionId) external;

    function settleAndResolve(uint256 marketId) external;

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);
}
