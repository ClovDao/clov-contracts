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
        uint256 indexed marketId, bytes32 indexed assertionId, address indexed asserter, bool outcome
    );

    event OutcomeConfirmed(uint256 indexed marketId, bytes32 indexed assertionId, bool outcome);

    event AssertionDisputed(uint256 indexed marketId, bytes32 indexed assertionId);

    /// @notice Emitted when a market is flagged for permissionless assertion (Community tier).
    event PermissionlessAssertionSet(uint256 indexed marketId);

    /// @notice Emitted when the permissionless-assertion flag is cleared (challenge, cancel).
    event PermissionlessAssertionCleared(uint256 indexed marketId);

    /// @notice Emitted when a Community market challenge is asserted on UMA.
    event MarketChallengeAsserted(
        uint256 indexed marketId, bytes32 indexed assertionId, address indexed asserter, bytes32 reasonIpfsHash
    );

    function assertOutcome(uint256 marketId, bool outcome, address asserter) external returns (bytes32 assertionId);

    /// @notice Flag a market as permissionless-assertable. Only callable by the MarketFactory.
    ///         Used for Community-tier markets so anyone bonded can assert the outcome.
    function setPermissionlessAssertion(uint256 marketId) external;

    /// @notice Revoke the permissionless-assertion flag. Only callable by the MarketFactory.
    ///         Used when a market is challenged or cancelled — restores allowlist-only asserting.
    function clearPermissionlessAssertion(uint256 marketId) external;

    /// @notice View: whether a market is currently flagged for permissionless assertion.
    function isPermissionlessAssertion(uint256 marketId) external view returns (bool);

    /// @notice Factory-only entrypoint to open an UMA assertion disputing a Community market's
    ///         validity. Pulls `CHALLENGE_BOND_AMOUNT` USDC from `asserter` and calls
    ///         `assertTruth` on UMA. Callback routes back into the factory.
    function assertMarketChallenge(uint256 marketId, bytes32 reasonIpfsHash, address asserter)
        external
        returns (bytes32 assertionId);

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    function assertionDisputedCallback(bytes32 assertionId) external;

    function settleAndResolve(uint256 marketId) external;

    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);
}
