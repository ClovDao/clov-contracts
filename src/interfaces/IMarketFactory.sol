// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
    /// @dev    `EscalatedToUma` indicates an admin Layer 1 decision was contested
    ///         and the dispute is now in flight on UMA OptimisticOracleV3.
    enum MarketCreationStatus {
        Pending,
        Active,
        Challenged,
        Cancelled,
        EscalatedToUma
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
    /// @dev    Layer 1 challenge bonds are escrowed inside the factory (not on UMA).
    ///         `escalator` and `escalated` track the optional Layer 2 path where the
    ///         creator or challenger contests the admin decision via UMA.
    ///         `resolutionDeadline` is the cooldown after admin resolution during
    ///         which an escalation is still permitted.
    struct MarketExtended {
        MarketTier tier;
        MarketCreationStatus creationStatus;
        uint256 challengeDeadline;
        address challenger;
        uint256 creatorFeeAccumulated;
        uint256 challengeBond;
        bytes32 challengeReasonHash;
        uint256 resolutionDeadline;
        bool escalated;
        address escalator;
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
    ///         `bond` is the challenger USDC bond escrowed inside the factory.
    event MarketChallenged(uint256 indexed marketId, address indexed challenger, bytes32 reasonIpfsHash, uint256 bond);

    /// @notice Emitted when a Community market transitions from Pending to Active after its challenge window closes.
    event MarketActivated(uint256 indexed marketId);

    /// @notice Emitted when an admin resolves a Layer 1 challenge.
    ///         `upheld == true` → challenger wins (market cancelled, deposit + bond paid to challenger).
    ///         `upheld == false` → creator wins (bond returned, market re-armed for short window).
    ///         `payee` is the recipient of the slashed bond / deposit transfer.
    event ChallengeResolved(uint256 indexed marketId, bool upheld, bytes32 reasonHash, address indexed payee);

    /// @notice Emitted when the creator or challenger contests the admin Layer 1 decision and
    ///         opens a UMA assertion to overturn it.
    event EscalatedToUma(uint256 indexed marketId, address indexed escalator);

    /// @notice Emitted when an owner-tunable bond parameter is updated. `paramName` is the
    ///         keccak256 hash of the parameter name (e.g. keccak256("challengeBond")).
    event BondParamUpdated(bytes32 indexed paramName, uint256 oldValue, uint256 newValue);

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
    /// @dev Raised when a factory entry point reserved for the oracle adapter is called by another address.
    error OnlyOracleAdapter(address caller);

    /// @dev Escalation flow errors.
    error NotEligibleToEscalate(address caller);
    error EscalationWindowClosed();
    error AlreadyEscalated();

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
    ///         bond is pulled into the factory (NOT to UMA) and held in internal escrow until an
    ///         admin resolves the challenge or the parties escalate to UMA.
    /// @param marketId        The market being challenged.
    /// @param reasonIpfsHash  IPFS hash of the off-chain evidence bundle.
    function challengeMarket(uint256 marketId, bytes32 reasonIpfsHash) external;

    /// @notice Admin (RESOLVER_ROLE) finds the challenge valid: cancels the market, pays the
    ///         creation deposit + challenge bond to the challenger, opens a 24h window during
    ///         which the creator may escalate to UMA.
    function resolveChallengeUpheld(uint256 marketId, bytes32 reasonHash) external;

    /// @notice Admin (RESOLVER_ROLE) rejects the challenge: returns the bond to the creator,
    ///         re-arms the challenge window for an additional 24h (NOT a fresh 48h), and opens
    ///         a 24h escalation window for the challenger.
    function resolveChallengeRejected(uint256 marketId, bytes32 reasonHash) external;

    /// @notice Escalate the admin's Layer 1 decision to UMA OptimisticOracleV3. Standing is
    ///         restricted to the market creator or the original challenger. The caller must
    ///         have approved the oracle adapter (NOT the factory) for the UMA bond, since the
    ///         adapter pulls the bond directly. One-shot: a market can only be escalated once.
    function escalateToUma(uint256 marketId) external;

    /// @notice Adapter-only callback: UMA upheld the escalation (admin Layer 1 decision overturned).
    function onEscalationUpheld(uint256 marketId) external;

    /// @notice Adapter-only callback: UMA rejected the escalation (admin Layer 1 decision stands).
    function onEscalationRejected(uint256 marketId) external;

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

    /// @notice Owner-only: update the per-Community-market challenge bond (USDC, 6 decimals).
    function setChallengeBond(uint256 newBond) external;

    /// @notice Owner-only: update the Featured-tier creation deposit.
    function setCreationDeposit(uint256 newDeposit) external;

    /// @notice Owner-only: update the Community-tier creation deposit.
    function setCommunityCreationDeposit(uint256 newDeposit) external;

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
