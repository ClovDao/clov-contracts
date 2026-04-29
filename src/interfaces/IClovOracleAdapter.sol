// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
        uint256 indexed marketId, bytes32 indexed assertionId, address indexed asserter, bool outcome
    );

    event OutcomeConfirmed(uint256 indexed marketId, bytes32 indexed assertionId, bool outcome);

    event AssertionDisputed(uint256 indexed marketId, bytes32 indexed assertionId);

    /// @notice Emitted when a market is flagged for permissionless assertion (Community tier).
    event PermissionlessAssertionSet(uint256 indexed marketId);

    /// @notice Emitted when the permissionless-assertion flag is cleared (challenge, cancel).
    event PermissionlessAssertionCleared(uint256 indexed marketId);

    /// @notice Emitted when a Community-market admin Layer 1 decision is escalated to UMA.
    event EscalationAsserted(
        uint256 indexed marketId, bytes32 indexed assertionId, address indexed asserter, bytes32 reasonHash
    );

    /// @notice Emitted when the owner-tunable UMA bond amount is updated.
    event BondAmountUpdated(uint256 oldValue, uint256 newValue);

    function assertOutcome(uint256 marketId, bool outcome, address asserter) external returns (bytes32 assertionId);

    /// @notice Flag a market as permissionless-assertable. Only callable by the MarketFactory.
    ///         Used for Community-tier markets so anyone bonded can assert the outcome.
    function setPermissionlessAssertion(uint256 marketId) external;

    /// @notice Revoke the permissionless-assertion flag. Only callable by the MarketFactory.
    ///         Used when a market is challenged or cancelled — restores allowlist-only asserting.
    function clearPermissionlessAssertion(uint256 marketId) external;

    /// @notice View: whether a market is currently flagged for permissionless assertion.
    function isPermissionlessAssertion(uint256 marketId) external view returns (bool);

    /// @notice Factory-only entrypoint to open a UMA assertion contesting an admin Layer 1 decision
    ///         on a Community market. Pulls the UMA bond (`bondAmount`) USDC from `asserter` and
    ///         calls `assertTruth`. The callback routes back into the factory via
    ///         `onEscalationUpheld` or `onEscalationRejected`.
    function assertEscalatedChallenge(uint256 marketId, bytes32 reasonHash, address asserter)
        external
        returns (bytes32 assertionId);

    /// @notice Owner-only: update the UMA bond required for outcome and escalation assertions.
    function setBondAmount(uint256 newBond) external;

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    function assertionDisputedCallback(bytes32 assertionId) external;

    function settleAndResolve(uint256 marketId) external;

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);
}
