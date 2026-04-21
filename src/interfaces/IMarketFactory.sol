// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarketFactory {
    enum MarketStatus {
        Created,
        Active,
        Resolving,
        Resolved,
        Cancelled
    }

    enum Category {
        Futbol,
        Basquet,
        Esports,
        Otros
    }

    /// @notice Market tier — Featured (admin-curated) or Community (permissionless, challenge-gated)
    enum MarketTier {
        Featured,
        Community
    }

    /// @notice Community market lifecycle state, tracked in MarketExtended.
    ///         Featured markets skip straight to Active and never transition here.
    enum MarketCreationStatus {
        Pending,
        Active,
        Challenged,
        Cancelled
    }

    struct MarketData {
        bytes32 questionId;
        bytes32 conditionId;
        address creator;
        string metadataURI;
        uint256 creationDeposit;
        uint256 resolutionTimestamp;
        MarketStatus status;
        Category category;
    }

    /// @notice Extended per-market data for Community tier support.
    ///         Featured markets populate only `tier` (Featured) and `creationStatus` (Active).
    /// @dev H.3.5 removed `challengerBond` — the challenger bond is now held on the
    ///      UMA OptimisticOracleV3, not escrowed inside the factory.
    struct MarketExtended {
        MarketTier tier;
        MarketCreationStatus creationStatus;
        uint256 challengeDeadline;
        address challenger;
        uint256 creatorFeeAccumulated;
    }

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        bytes32 conditionId,
        bytes32 questionId,
        string metadataURI,
        uint256 resolutionTimestamp,
        Category category
    );

    event MarketStatusChanged(uint256 indexed marketId, MarketStatus newStatus);

    event CreationDepositRefunded(uint256 indexed marketId, address indexed creator, uint256 amount);

    event CreationDepositUpdated(uint256 oldDeposit, uint256 newDeposit);

    event MarketCancelled(uint256 indexed marketId, address indexed cancelledBy);

    /// @notice Emitted when a Community market is created. Featured markets only emit MarketCreated.
    event CommunityMarketCreated(
        uint256 indexed marketId, address indexed creator, uint256 challengeDeadline, uint256 creationDeposit
    );

    /// @notice Emitted when a Community market is challenged within its 48h window.
    ///         `reasonIpfsHash` points to the off-chain evidence bundle supporting the challenge.
    event MarketChallenged(uint256 indexed marketId, address indexed challenger, bytes32 reasonIpfsHash);

    /// @notice Emitted when a Community market transitions from Pending to Active after its challenge window closes.
    event MarketActivated(uint256 indexed marketId);

    /// @notice Emitted when a challenge is upheld by UMA — deposit is transferred to the challenger.
    event ChallengeUpheld(uint256 indexed marketId, address indexed challenger, uint256 deposit);

    /// @notice Emitted when a challenge is rejected by UMA — market returns to Pending with extended deadline.
    event ChallengeRejected(uint256 indexed marketId, uint256 newChallengeDeadline);

    /// @notice Emitted when a Community market creator withdraws their accrued fee share.
    event CreatorFeeClaimed(uint256 indexed marketId, address indexed creator, uint256 amount);

    /// @notice Emitted when a Community market's creator fee bucket accrues new trading fees.
    event CreatorFeeAccrued(uint256 indexed marketId, uint256 amount);

    /// @notice Emitted when admin updates the community creation deposit.
    event CommunityCreationDepositUpdated(uint256 oldDeposit, uint256 newDeposit);

    /// @dev Community-tier specific errors.
    error ChallengeWindowClosed();
    error ChallengeWindowStillOpen();
    error AlreadyChallenged();
    error NoCreatorFeeToClaim();
    error NotCommunityMarket(uint256 marketId);
    error InvalidMarketTransition(MarketCreationStatus from, MarketCreationStatus to);
    /// @dev Raised when an onChallengeUpheld / onChallengeRejected callback is not from the oracle adapter.
    error OnlyOracleAdapter(address caller);

    function createMarket(string calldata metadataURI, uint256 resolutionTimestamp, Category category)
        external
        returns (uint256 marketId);

    /// @notice Permissionless Community-market creation. Caller escrows `communityCreationDeposit`
    ///         USDC, opens a 48h challenge window, and receives a share of trading fees post-activation
    ///         (split computed off-chain). Any address may call; reverts if factory is paused.
    function createCommunityMarket(string calldata metadataURI, uint256 resolutionTimestamp, Category category)
        external
        returns (uint256 marketId);

    /// @notice Challenge a Pending Community market within its challenge window. The challenger's
    ///         bond is pulled by the oracle adapter and escrowed on UMA OptimisticOracleV3 via
    ///         `assertMarketChallenge`. Transitions market to Challenged.
    /// @param marketId        The market being challenged.
    /// @param reasonIpfsHash  IPFS hash of the off-chain evidence bundle (keccak-sized digest).
    function challengeMarket(uint256 marketId, bytes32 reasonIpfsHash) external;

    /// @notice Oracle-only callback: UMA upheld the challenge. Transfers the creation deposit to
    ///         the challenger and moves the market to Cancelled.
    function onChallengeUpheld(uint256 marketId) external;

    /// @notice Oracle-only callback: UMA rejected the challenge. Resets the market to Pending and
    ///         extends the challenge deadline by `CHALLENGE_PERIOD`, re-enabling permissionless
    ///         assertion for outcome resolution.
    function onChallengeRejected(uint256 marketId) external;

    /// @notice Activate a Community market once its challenge window has closed and no challenge
    ///         was filed. Permissionless. Transitions Pending -> Active.
    function activateMarket(uint256 marketId) external;

    /// @notice Claim accrued creator fees for a Community market. Only callable by the market creator.
    ///         Resets `creatorFeeAccumulated` to zero and transfers USDC to the creator.
    function claimCreatorFee(uint256 marketId) external;

    /// @notice Accrue creator fees on a Community market. Called by CTFExchange / NegRiskCtfExchange
    ///         fee-routing logic. Reverts if `marketId` is not a Community market.
    function accrueCreatorFee(uint256 marketId, uint256 amount) external;

    function pauseMarketCreation() external;

    function unpauseMarketCreation() external;

    function updateCreationDeposit(uint256 newDeposit) external;

    /// @notice Admin-only: update the Community creation deposit amount (must be >= MIN_CREATION_DEPOSIT).
    function updateCommunityCreationDeposit(uint256 newDeposit) external;

    function getMarket(uint256 marketId) external view returns (MarketData memory);

    /// @notice Return tier + lifecycle data for a market. Featured markets return
    ///         `tier=Featured, creationStatus=Active` with zero-valued challenge fields.
    function getMarketExtended(uint256 marketId) external view returns (MarketExtended memory);

    function refundCreationDeposit(uint256 marketId) external;

    function updateMarketStatus(uint256 marketId, MarketStatus newStatus) external;

    function cancelMarket(uint256 marketId) external;
}
