// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IConditionalTokens } from "./interfaces/IConditionalTokens.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";
import { IClovOracleAdapter } from "./interfaces/IClovOracleAdapter.sol";

/// @notice Minimal interface to the CTF Exchange registerToken surface.
///         Full ABI lives in `src/exchange/CTFExchange.sol` — we only need the one call
///         plus the admin-check it enforces internally.
interface ICTFExchangeRegistry {
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId) external;
}

/// @title MarketFactory
/// @notice Factory contract for creating and managing prediction markets
/// @dev Uses Gnosis Conditional Tokens for outcome tracking. Trading is handled
///      externally by a CLOB (CTF Exchange), not by this contract.
contract MarketFactory is IMarketFactory, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error InvalidResolutionTimestamp();
    error MarketNotResolvedOrCancelled(uint256 marketId);
    error NotMarketCreator(uint256 marketId, address caller);
    error DepositAlreadyRefunded(uint256 marketId);
    error UnauthorizedStatusUpdate(address caller);
    error InvalidStateTransition(MarketStatus currentStatus, MarketStatus newStatus);
    error AlreadyInitialized();
    error MarketDoesNotExist(uint256 marketId);
    error DepositBelowMinimum(uint256 provided, uint256 minimum);

    /// @notice Minimum creation deposit: 1 USDC (6 decimals)
    uint256 public constant MIN_CREATION_DEPOSIT = 1e6;

    /// @notice Challenge window for Community markets: 48 hours from creation.
    uint256 public constant CHALLENGE_PERIOD = 48 hours;

    /// @notice Basis-points denominator (10_000 = 100%). Retained for off-chain callers.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ──────────────────────────────────────────────
    // Immutable / External Contracts
    // ──────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    IConditionalTokens public immutable conditionalTokens;

    /// @notice CTFExchange instance on which this factory is an immutable admin. Each Community
    ///         market activation registers its YES/NO tokenIds on the exchange.
    ICTFExchangeRegistry public immutable ctfExchange;

    // ──────────────────────────────────────────────
    // Privileged Addresses (set post-deploy via initialize)
    // ──────────────────────────────────────────────

    address public oracleAdapter;
    address public marketResolver;

    // ──────────────────────────────────────────────
    // Configuration
    // ──────────────────────────────────────────────

    /// @notice Anti-spam deposit required to create a market (in collateral token units)
    uint256 public creationDeposit;

    /// @notice Anti-spam deposit required to create a Community-tier market.
    ///         Defaults to 50 USDC; changeable by owner via updateCommunityCreationDeposit.
    uint256 public communityCreationDeposit = 50e6;

    // ──────────────────────────────────────────────
    // Market State
    // ──────────────────────────────────────────────

    /// @notice Auto-increment market ID counter
    uint256 public marketCount;

    /// @notice marketId => MarketData
    mapping(uint256 => MarketData) public markets;

    /// @notice questionId => marketId (reverse lookup)
    mapping(bytes32 => uint256) public questionIdToMarketId;

    /// @notice marketId => MarketExtended (tier, creation status, challenge data, creator fee accrual).
    mapping(uint256 => MarketExtended) internal _extendedData;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address _collateralToken, address _conditionalTokens, address _ctfExchange, uint256 _creationDeposit)
        Ownable(msg.sender)
    {
        if (_collateralToken == address(0) || _conditionalTokens == address(0) || _ctfExchange == address(0)) {
            revert ZeroAddress();
        }

        if (_creationDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(_creationDeposit, MIN_CREATION_DEPOSIT);
        }

        collateralToken = IERC20(_collateralToken);
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        ctfExchange = ICTFExchangeRegistry(_ctfExchange);
        creationDeposit = _creationDeposit;
    }

    /// @notice One-time initialization of cross-references (resolves circular dependency)
    /// @param _oracleAdapter Address of the ClovOracleAdapter
    /// @param _marketResolver Address of the MarketResolver
    function initialize(address _oracleAdapter, address _marketResolver) external onlyOwner {
        if (oracleAdapter != address(0) || marketResolver != address(0)) {
            revert AlreadyInitialized();
        }
        if (_oracleAdapter == address(0) || _marketResolver == address(0)) {
            revert ZeroAddress();
        }
        oracleAdapter = _oracleAdapter;
        marketResolver = _marketResolver;
    }

    // ──────────────────────────────────────────────
    // Market Creation
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    /// @dev Featured markets are Active immediately. Registers the YES/NO CTF tokens on the
    ///      exchange in the same call so trading is live on market creation.
    function createMarket(string calldata metadataURI, uint256 resolutionTimestamp, Category category)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        (uint256 marketId, bytes32 conditionId) = _createMarketInternal(
            metadataURI, resolutionTimestamp, category, creationDeposit, MarketStatus.Active
        );

        // Populate extended state for Featured tier (Active, no challenge window).
        _extendedData[marketId] = MarketExtended({
            tier: MarketTier.Featured,
            creationStatus: MarketCreationStatus.Active,
            challengeDeadline: 0,
            challenger: address(0),
            creatorFeeAccumulated: 0
        });

        _registerTokensOnExchange(conditionId);

        return marketId;
    }

    /// @inheritdoc IMarketFactory
    /// @dev Community markets are permissionless. They charge `communityCreationDeposit` (default 50 USDC)
    ///      and open a CHALLENGE_PERIOD (48h) window during which any bonded party may dispute via
    ///      challengeMarket. Token registration on the exchange is deferred to `activateMarket`.
    function createCommunityMarket(string calldata metadataURI, uint256 resolutionTimestamp, Category category)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 deposit = communityCreationDeposit;
        (uint256 marketId,) =
            _createMarketInternal(metadataURI, resolutionTimestamp, category, deposit, MarketStatus.Created);

        uint256 deadline = block.timestamp + CHALLENGE_PERIOD;
        _extendedData[marketId] = MarketExtended({
            tier: MarketTier.Community,
            creationStatus: MarketCreationStatus.Pending,
            challengeDeadline: deadline,
            challenger: address(0),
            creatorFeeAccumulated: 0
        });

        // Community markets bypass the asserter allowlist so outcome resolution is
        // permissionless. Flag is cleared on challenge or cancel.
        IClovOracleAdapter(oracleAdapter).setPermissionlessAssertion(marketId);

        emit CommunityMarketCreated(marketId, msg.sender, deadline, deposit);

        return marketId;
    }

    /// @dev Shared creation path for Featured and Community tiers. Validates, pulls deposit,
    ///      prepares the CT condition, persists MarketData, emits MarketCreated, increments counter.
    ///      Tier-specific extended state and deposit amounts are applied by the caller.
    function _createMarketInternal(
        string calldata metadataURI,
        uint256 resolutionTimestamp,
        Category category,
        uint256 deposit,
        MarketStatus businessStatus
    ) internal returns (uint256 marketId, bytes32 conditionId) {
        if (resolutionTimestamp <= block.timestamp + 1 hours) {
            revert InvalidResolutionTimestamp();
        }

        collateralToken.safeTransferFrom(msg.sender, address(this), deposit);

        bytes32 questionId =
            keccak256(abi.encodePacked(block.chainid, address(this), marketCount, msg.sender, block.timestamp));
        conditionalTokens.prepareCondition(marketResolver, questionId, 2);
        conditionId = conditionalTokens.getConditionId(marketResolver, questionId, 2);

        marketId = marketCount;
        markets[marketId] = MarketData({
            questionId: questionId,
            conditionId: conditionId,
            creator: msg.sender,
            metadataURI: metadataURI,
            creationDeposit: deposit,
            resolutionTimestamp: resolutionTimestamp,
            status: businessStatus,
            category: category
        });

        questionIdToMarketId[questionId] = marketId;
        marketCount++;

        emit MarketCreated(marketId, msg.sender, conditionId, questionId, metadataURI, resolutionTimestamp, category);
    }

    /// @dev Compute binary YES/NO CTF positionIds for the given conditionId and register them
    ///      on the exchange. Called at market activation (Featured in createMarket, Community
    ///      in activateMarket). Requires the factory to hold admin role on the exchange.
    function _registerTokensOnExchange(bytes32 conditionId) internal {
        // YES (indexSet=1), NO (indexSet=2) under parent collection 0.
        bytes32 yesCollection = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollection = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesTokenId = conditionalTokens.getPositionId(collateralToken, yesCollection);
        uint256 noTokenId = conditionalTokens.getPositionId(collateralToken, noCollection);

        ctfExchange.registerToken(yesTokenId, noTokenId, conditionId);
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    function pauseMarketCreation() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IMarketFactory
    function unpauseMarketCreation() external override onlyOwner {
        _unpause();
    }

    /// @inheritdoc IMarketFactory
    function updateCreationDeposit(uint256 newDeposit) external override onlyOwner {
        if (newDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(newDeposit, MIN_CREATION_DEPOSIT);
        }
        uint256 oldDeposit = creationDeposit;
        creationDeposit = newDeposit;
        emit CreationDepositUpdated(oldDeposit, newDeposit);
    }

    /// @inheritdoc IMarketFactory
    function updateMarketStatus(uint256 marketId, MarketStatus newStatus) external override {
        if (msg.sender != oracleAdapter && msg.sender != marketResolver) {
            revert UnauthorizedStatusUpdate(msg.sender);
        }

        MarketStatus currentStatus = markets[marketId].status;
        if (!_isValidTransition(currentStatus, newStatus)) {
            revert InvalidStateTransition(currentStatus, newStatus);
        }

        markets[marketId].status = newStatus;
        emit MarketStatusChanged(marketId, newStatus);
    }

    /// @notice Emergency cancel a market — returns deposits, prevents further trading
    /// @dev Only callable by the contract owner. Validates state transition via _isValidTransition.
    /// @param marketId The ID of the market to cancel
    function cancelMarket(uint256 marketId) external override onlyOwner {
        MarketData storage m = markets[marketId];

        if (m.creator == address(0)) {
            revert MarketDoesNotExist(marketId);
        }

        // Forbid cancelling a community market while a UMA challenge is in flight.
        // Cancelling mid-challenge would leave the creationDeposit claimable by the
        // creator via refundCreationDeposit, robbing the challenger of their reward.
        // Admin must wait for UMA resolution (onChallengeUpheld / onChallengeRejected).
        MarketExtended storage extRef = _extendedData[marketId];
        if (extRef.tier == MarketTier.Community && extRef.creationStatus == MarketCreationStatus.Challenged) {
            revert InvalidMarketTransition(extRef.creationStatus, MarketCreationStatus.Cancelled);
        }

        MarketStatus currentStatus = m.status;
        if (!_isValidTransition(currentStatus, MarketStatus.Cancelled)) {
            revert InvalidStateTransition(currentStatus, MarketStatus.Cancelled);
        }

        m.status = MarketStatus.Cancelled;

        // Community markets may have permissionless asserting enabled — revoke on cancel.
        MarketExtended storage ext = _extendedData[marketId];
        if (ext.tier == MarketTier.Community && ext.creationStatus == MarketCreationStatus.Pending) {
            ext.creationStatus = MarketCreationStatus.Cancelled;
            IClovOracleAdapter(oracleAdapter).clearPermissionlessAssertion(marketId);
        }

        emit MarketCancelled(marketId, msg.sender);
        emit MarketStatusChanged(marketId, MarketStatus.Cancelled);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    function getMarket(uint256 marketId) external view override returns (MarketData memory) {
        return markets[marketId];
    }

    // ──────────────────────────────────────────────
    // Creator Functions
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    function refundCreationDeposit(uint256 marketId) external override nonReentrant {
        MarketData storage m = markets[marketId];

        if (m.status != MarketStatus.Resolved && m.status != MarketStatus.Cancelled) {
            revert MarketNotResolvedOrCancelled(marketId);
        }
        if (m.creator != msg.sender) {
            revert NotMarketCreator(marketId, msg.sender);
        }
        if (m.creationDeposit == 0) {
            revert DepositAlreadyRefunded(marketId);
        }

        uint256 amount = m.creationDeposit;
        m.creationDeposit = 0;

        collateralToken.safeTransfer(msg.sender, amount);

        emit CreationDepositRefunded(marketId, msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    // Internal Helpers
    // ──────────────────────────────────────────────

    /// @dev Validates that a state transition is allowed
    /// @param currentStatus The current status of the market
    /// @param newStatus The proposed new status
    /// @return valid True if the transition is allowed
    function _isValidTransition(MarketStatus currentStatus, MarketStatus newStatus) internal pure returns (bool valid) {
        // Created → Active
        if (currentStatus == MarketStatus.Created && newStatus == MarketStatus.Active) return true;
        // Created → Cancelled (owner cancels a Community market still in its challenge window)
        if (currentStatus == MarketStatus.Created && newStatus == MarketStatus.Cancelled) return true;
        // Active → Resolving
        if (currentStatus == MarketStatus.Active && newStatus == MarketStatus.Resolving) return true;
        // Active → Cancelled (emergency cancel)
        if (currentStatus == MarketStatus.Active && newStatus == MarketStatus.Cancelled) return true;
        // Resolving → Cancelled (emergency cancel during dispute)
        if (currentStatus == MarketStatus.Resolving && newStatus == MarketStatus.Cancelled) return true;
        // Resolving → Active (assertion disputed)
        if (currentStatus == MarketStatus.Resolving && newStatus == MarketStatus.Active) return true;
        // Resolving → Resolved (assertion confirmed)
        if (currentStatus == MarketStatus.Resolving && newStatus == MarketStatus.Resolved) return true;
        // All other transitions are invalid (Resolved and Cancelled are terminal)
        return false;
    }

    // ──────────────────────────────────────────────
    // Community Markets — Challenge / Activate / Callbacks
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    /// @dev Permissionless. The challenger's USDC bond is pulled directly by the oracle adapter
    ///      and escrowed on UMA — no bond is held in this contract.
    function challengeMarket(uint256 marketId, bytes32 reasonIpfsHash) external override nonReentrant {
        MarketExtended storage ext = _extendedData[marketId];

        if (ext.tier != MarketTier.Community) {
            revert NotCommunityMarket(marketId);
        }
        if (ext.creationStatus == MarketCreationStatus.Challenged) {
            revert AlreadyChallenged();
        }
        if (ext.creationStatus != MarketCreationStatus.Pending) {
            revert InvalidMarketTransition(ext.creationStatus, MarketCreationStatus.Challenged);
        }
        if (block.timestamp > ext.challengeDeadline) {
            revert ChallengeWindowClosed();
        }

        ext.creationStatus = MarketCreationStatus.Challenged;
        ext.challenger = msg.sender;

        // Dispute in flight — revoke permissionless asserting until resolution.
        IClovOracleAdapter adapter = IClovOracleAdapter(oracleAdapter);
        adapter.clearPermissionlessAssertion(marketId);

        // Adapter pulls the UMA bond from the challenger and opens the assertion.
        adapter.assertMarketChallenge(marketId, reasonIpfsHash, msg.sender);

        emit MarketChallenged(marketId, msg.sender, reasonIpfsHash);
    }

    /// @inheritdoc IMarketFactory
    function onChallengeUpheld(uint256 marketId) external override nonReentrant {
        if (msg.sender != oracleAdapter) {
            revert OnlyOracleAdapter(msg.sender);
        }

        MarketExtended storage ext = _extendedData[marketId];
        MarketData storage m = markets[marketId];
        address challenger = ext.challenger;
        uint256 deposit = m.creationDeposit;

        // Move market to Cancelled (business status) and mark Community lifecycle Cancelled.
        ext.creationStatus = MarketCreationStatus.Cancelled;
        m.status = MarketStatus.Cancelled;
        m.creationDeposit = 0;

        if (deposit > 0 && challenger != address(0)) {
            collateralToken.safeTransfer(challenger, deposit);
        }

        emit ChallengeUpheld(marketId, challenger, deposit);
        emit MarketCancelled(marketId, challenger);
        emit MarketStatusChanged(marketId, MarketStatus.Cancelled);
    }

    /// @inheritdoc IMarketFactory
    function onChallengeRejected(uint256 marketId) external override nonReentrant {
        if (msg.sender != oracleAdapter) {
            revert OnlyOracleAdapter(msg.sender);
        }

        MarketExtended storage ext = _extendedData[marketId];

        ext.creationStatus = MarketCreationStatus.Pending;
        ext.challenger = address(0);

        uint256 newDeadline = block.timestamp + CHALLENGE_PERIOD;
        ext.challengeDeadline = newDeadline;

        // Restore permissionless assertion path so outcome resolution can resume post-activation.
        IClovOracleAdapter(oracleAdapter).setPermissionlessAssertion(marketId);

        emit ChallengeRejected(marketId, newDeadline);
    }

    /// @inheritdoc IMarketFactory
    /// @dev Permissionless. Promotes a Pending Community market whose 48h challenge window
    ///      has closed without dispute. Extended lifecycle Pending -> Active, business
    ///      status Created -> Active so trading can begin. Registers YES/NO CTF tokenIds
    ///      on the exchange.
    function activateMarket(uint256 marketId) external override {
        MarketExtended storage ext = _extendedData[marketId];

        if (ext.tier != MarketTier.Community) {
            revert NotCommunityMarket(marketId);
        }
        if (ext.creationStatus != MarketCreationStatus.Pending) {
            revert InvalidMarketTransition(ext.creationStatus, MarketCreationStatus.Active);
        }
        if (block.timestamp <= ext.challengeDeadline) {
            revert ChallengeWindowStillOpen();
        }

        MarketData storage m = markets[marketId];
        MarketStatus current = m.status;
        if (!_isValidTransition(current, MarketStatus.Active)) {
            revert InvalidStateTransition(current, MarketStatus.Active);
        }

        ext.creationStatus = MarketCreationStatus.Active;
        m.status = MarketStatus.Active;

        _registerTokensOnExchange(m.conditionId);

        emit MarketActivated(marketId);
        emit MarketStatusChanged(marketId, MarketStatus.Active);
    }

    /// @inheritdoc IMarketFactory
    /// @dev Only the market creator may withdraw accrued fees. Resets the bucket to zero
    ///      before transferring to avoid reentrant double-claim.
    function claimCreatorFee(uint256 marketId) external override nonReentrant {
        MarketExtended storage ext = _extendedData[marketId];
        if (ext.tier != MarketTier.Community) {
            revert NotCommunityMarket(marketId);
        }

        address creator = markets[marketId].creator;
        if (msg.sender != creator) {
            revert NotMarketCreator(marketId, msg.sender);
        }

        uint256 amount = ext.creatorFeeAccumulated;
        if (amount == 0) {
            revert NoCreatorFeeToClaim();
        }

        ext.creatorFeeAccumulated = 0;
        collateralToken.safeTransfer(creator, amount);

        emit CreatorFeeClaimed(marketId, creator, amount);
    }

    /// @inheritdoc IMarketFactory
    /// @dev Permissionless by design: any caller may pull-transfer USDC in, so only
    ///      parties that already hold fee revenue benefit from calling it.
    function accrueCreatorFee(uint256 marketId, uint256 amount) external override nonReentrant {
        MarketExtended storage ext = _extendedData[marketId];
        if (ext.tier != MarketTier.Community) {
            revert NotCommunityMarket(marketId);
        }

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        ext.creatorFeeAccumulated += amount;

        emit CreatorFeeAccrued(marketId, amount);
    }

    /// @inheritdoc IMarketFactory
    function updateCommunityCreationDeposit(uint256 newDeposit) external override onlyOwner {
        if (newDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(newDeposit, MIN_CREATION_DEPOSIT);
        }
        uint256 old = communityCreationDeposit;
        communityCreationDeposit = newDeposit;
        emit CommunityCreationDepositUpdated(old, newDeposit);
    }

    /// @inheritdoc IMarketFactory
    function getMarketExtended(uint256 marketId) external view override returns (MarketExtended memory) {
        return _extendedData[marketId];
    }

    /// @notice Returns true iff the market is Community-tier AND currently Active (challenge
    ///         window closed, no unresolved dispute). Consumed by `ClovCommunityExecutor` to
    ///         gate community-only fee distribution — prevents routing through the community
    ///         fee path while a market is still Pending or Challenged.
    function isCommunityMarket(uint256 marketId) external view returns (bool) {
        MarketExtended storage ext = _extendedData[marketId];
        return ext.tier == MarketTier.Community && ext.creationStatus == MarketCreationStatus.Active;
    }
}
