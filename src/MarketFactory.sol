// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
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
/// @notice Factory contract for creating and managing prediction markets.
/// @dev    Uses Gnosis Conditional Tokens for outcome tracking. Trading is handled
///         externally by a CLOB (CTF Exchange), not by this contract.
///
///         Community-market disputes follow a two-layer flow:
///         - Layer 1: anyone may post a USDC bond (`challengeBond`) to challenge a market in its
///           48h window. The bond is escrowed inside this contract. A RESOLVER_ROLE admin
///           adjudicates within the SLA via `resolveChallengeUpheld` / `resolveChallengeRejected`.
///         - Layer 2 (optional): the loser of the admin decision (creator or challenger) may
///           escalate the case to UMA OptimisticOracleV3 within a 24h cooldown by calling
///           `escalateToUma`. The adapter pulls a separate UMA bond directly from the escalator.
contract MarketFactory is IMarketFactory, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    /// @notice Owner: can pause, tune bonds, cancel markets, and manage roles.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Resolver: adjudicates Layer 1 community-market challenges.
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

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

    /// @notice Re-arm window after an admin rejects a challenge, and the cooldown during
    ///         which the loser of an admin Layer 1 decision may still escalate to UMA.
    uint256 public constant POST_RESOLUTION_PERIOD = 24 hours;

    /// @notice Default per-market challenge bond — 50 USDC (6 decimals).
    uint256 public constant DEFAULT_CHALLENGE_BOND = 50e6;

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
    // Configuration (mutable, owner-tunable)
    // ──────────────────────────────────────────────

    /// @notice Anti-spam deposit required to create a Featured market (in collateral token units).
    uint256 public creationDeposit;

    /// @notice Anti-spam deposit required to create a Community-tier market.
    ///         Defaults to 50 USDC.
    uint256 public communityCreationDeposit = 50e6;

    /// @notice Per-challenge USDC bond required from a challenger of a Community market.
    ///         Held in internal escrow until adjudicated.
    uint256 public challengeBond;

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

    constructor(address _collateralToken, address _conditionalTokens, address _ctfExchange, uint256 _creationDeposit) {
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
        challengeBond = DEFAULT_CHALLENGE_BOND;

        // Deployer bootstraps both admin and owner roles. Deployment scripts may
        // hand off OWNER_ROLE to a multisig / timelock and renounce DEFAULT_ADMIN_ROLE.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OWNER_ROLE, msg.sender);
    }

    /// @notice One-time initialization of cross-references (resolves circular dependency)
    /// @param _oracleAdapter Address of the ClovOracleAdapter
    /// @param _marketResolver Address of the MarketResolver
    function initialize(address _oracleAdapter, address _marketResolver) external onlyRole(OWNER_ROLE) {
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
        MarketExtended storage ext = _extendedData[marketId];
        ext.tier = MarketTier.Featured;
        ext.creationStatus = MarketCreationStatus.Active;

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
        MarketExtended storage ext = _extendedData[marketId];
        ext.tier = MarketTier.Community;
        ext.creationStatus = MarketCreationStatus.Pending;
        ext.challengeDeadline = deadline;

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
    function pauseMarketCreation() external override onlyRole(OWNER_ROLE) {
        _pause();
    }

    /// @inheritdoc IMarketFactory
    function unpauseMarketCreation() external override onlyRole(OWNER_ROLE) {
        _unpause();
    }

    /// @inheritdoc IMarketFactory
    function updateCreationDeposit(uint256 newDeposit) external override onlyRole(OWNER_ROLE) {
        if (newDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(newDeposit, MIN_CREATION_DEPOSIT);
        }
        uint256 oldDeposit = creationDeposit;
        creationDeposit = newDeposit;
        emit CreationDepositUpdated(oldDeposit, newDeposit);
    }

    /// @inheritdoc IMarketFactory
    /// @dev Alias of `updateCreationDeposit` exposing the unified `BondParamUpdated` telemetry
    ///      event used for off-chain bond-parameter dashboards.
    function setCreationDeposit(uint256 newDeposit) external override onlyRole(OWNER_ROLE) {
        if (newDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(newDeposit, MIN_CREATION_DEPOSIT);
        }
        uint256 oldDeposit = creationDeposit;
        creationDeposit = newDeposit;
        emit BondParamUpdated(keccak256("creationDeposit"), oldDeposit, newDeposit);
    }

    /// @inheritdoc IMarketFactory
    function setCommunityCreationDeposit(uint256 newDeposit) external override onlyRole(OWNER_ROLE) {
        if (newDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(newDeposit, MIN_CREATION_DEPOSIT);
        }
        uint256 oldDeposit = communityCreationDeposit;
        communityCreationDeposit = newDeposit;
        emit BondParamUpdated(keccak256("communityCreationDeposit"), oldDeposit, newDeposit);
    }

    /// @inheritdoc IMarketFactory
    function setChallengeBond(uint256 newBond) external override onlyRole(OWNER_ROLE) {
        uint256 oldBond = challengeBond;
        challengeBond = newBond;
        emit BondParamUpdated(keccak256("challengeBond"), oldBond, newBond);
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
    /// @dev Only callable by OWNER_ROLE. Validates state transition via _isValidTransition.
    ///      Forbids cancelling a community market while a Layer 1 challenge is pending or
    ///      escalated; admin must adjudicate / await UMA settlement first.
    /// @param marketId The ID of the market to cancel
    function cancelMarket(uint256 marketId) external override onlyRole(OWNER_ROLE) {
        MarketData storage m = markets[marketId];

        if (m.creator == address(0)) {
            revert MarketDoesNotExist(marketId);
        }

        // Forbid cancelling a community market while a challenge is in flight (admin pending
        // or already escalated to UMA). Admin must adjudicate first; otherwise the bond
        // accounting between creator/challenger would be ambiguous.
        MarketExtended storage extRef = _extendedData[marketId];
        if (
            extRef.tier == MarketTier.Community
                && (extRef.creationStatus == MarketCreationStatus.Challenged
                    || extRef.creationStatus == MarketCreationStatus.EscalatedToUma)
        ) {
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
    // Community Markets — Layer 1 Challenge
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    /// @dev Permissionless. The challenger's USDC bond is escrowed inside this contract until a
    ///      RESOLVER_ROLE admin adjudicates. There is NO call to UMA at this stage — the UMA path
    ///      is reserved for the Layer 2 escalation flow (`escalateToUma`).
    function challengeMarket(uint256 marketId, bytes32 reasonIpfsHash) external override nonReentrant {
        MarketExtended storage ext = _extendedData[marketId];

        if (ext.tier != MarketTier.Community) {
            revert NotCommunityMarket(marketId);
        }
        if (ext.creationStatus != MarketCreationStatus.Pending) {
            revert InvalidMarketTransition(ext.creationStatus, MarketCreationStatus.Challenged);
        }
        if (block.timestamp > ext.challengeDeadline) {
            revert ChallengeWindowClosed();
        }

        uint256 bond = challengeBond;

        ext.creationStatus = MarketCreationStatus.Challenged;
        ext.challenger = msg.sender;
        ext.challengeBond = bond;
        ext.challengeReasonHash = reasonIpfsHash;

        // Pull the bond into internal escrow (NOT to UMA).
        collateralToken.safeTransferFrom(msg.sender, address(this), bond);

        // Dispute in flight — revoke permissionless asserting until resolution.
        IClovOracleAdapter(oracleAdapter).clearPermissionlessAssertion(marketId);

        emit MarketChallenged(marketId, msg.sender, reasonIpfsHash, bond);
    }

    /// @inheritdoc IMarketFactory
    /// @dev RESOLVER_ROLE only. Admin found the challenge valid: market is cancelled and the
    ///      challenger receives the creation deposit + their bond back. The 24h `resolutionDeadline`
    ///      gives the creator a chance to escalate the decision to UMA.
    function resolveChallengeUpheld(uint256 marketId, bytes32 reasonHash)
        external
        override
        onlyRole(RESOLVER_ROLE)
        nonReentrant
    {
        MarketExtended storage ext = _extendedData[marketId];
        if (ext.creationStatus != MarketCreationStatus.Challenged) {
            revert InvalidMarketTransition(ext.creationStatus, MarketCreationStatus.Cancelled);
        }

        MarketData storage m = markets[marketId];
        address challenger = ext.challenger;
        uint256 deposit = m.creationDeposit;
        uint256 chBond = ext.challengeBond;

        ext.creationStatus = MarketCreationStatus.Cancelled;
        m.status = MarketStatus.Cancelled;
        m.creationDeposit = 0;
        ext.challengeBond = 0;
        ext.resolutionDeadline = block.timestamp + POST_RESOLUTION_PERIOD;

        uint256 payout = deposit + chBond;
        if (payout > 0 && challenger != address(0)) {
            collateralToken.safeTransfer(challenger, payout);
        }

        emit ChallengeResolved(marketId, true, reasonHash, challenger);
        emit MarketCancelled(marketId, challenger);
        emit MarketStatusChanged(marketId, MarketStatus.Cancelled);
    }

    /// @inheritdoc IMarketFactory
    /// @dev RESOLVER_ROLE only. Admin found the challenge invalid: the challenger's bond is
    ///      forfeited to the market creator (slashing) and the market is re-armed for a 24h
    ///      window (NOT a fresh 48h) so a different party may file a fresh challenge. The
    ///      original challenger keeps standing on `ext.challenger` for the same 24h to
    ///      optionally escalate the admin decision to UMA.
    function resolveChallengeRejected(uint256 marketId, bytes32 reasonHash)
        external
        override
        onlyRole(RESOLVER_ROLE)
        nonReentrant
    {
        MarketExtended storage ext = _extendedData[marketId];
        if (ext.creationStatus != MarketCreationStatus.Challenged) {
            revert InvalidMarketTransition(ext.creationStatus, MarketCreationStatus.Pending);
        }

        address creator = markets[marketId].creator;
        uint256 chBond = ext.challengeBond;

        ext.creationStatus = MarketCreationStatus.Pending;
        ext.challengeBond = 0;
        ext.resolutionDeadline = block.timestamp + POST_RESOLUTION_PERIOD;
        // Re-arm the challenge window for at least POST_RESOLUTION_PERIOD, but never shrink an
        // originally-far-future deadline: a late admin rejection must not curtail the time a
        // fresh challenger had at creation time.
        uint256 reArm = block.timestamp + POST_RESOLUTION_PERIOD;
        if (reArm > ext.challengeDeadline) {
            ext.challengeDeadline = reArm;
        }

        if (chBond > 0 && creator != address(0)) {
            collateralToken.safeTransfer(creator, chBond);
        }

        // Restore permissionless assertion path for outcome resolution.
        IClovOracleAdapter(oracleAdapter).setPermissionlessAssertion(marketId);

        emit ChallengeResolved(marketId, false, reasonHash, creator);
    }

    // ──────────────────────────────────────────────
    // Community Markets — Layer 2 UMA Escalation
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    /// @dev Standing: only the LOSER of the admin Layer 1 decision may escalate. If the admin
    ///      upheld the challenge (state=Cancelled), the creator lost and can escalate. If the
    ///      admin rejected the challenge (state=Pending), the original challenger lost and can
    ///      escalate. Symmetric standing would let the winner self-escalate to grief the loser
    ///      by burning a UMA bond against an already-decided outcome.
    ///
    ///      Cooldown: callable only within `POST_RESOLUTION_PERIOD` of an admin decision.
    ///      Escalation before an admin acts is forbidden so the L1 escrow has a single,
    ///      well-defined disbursement path. One-shot per market (`escalated`).
    ///
    ///      UX note: the caller must have approved the oracle adapter (NOT this factory)
    ///      for the UMA bond, since the adapter pulls it directly via
    ///      `assertEscalatedChallenge`. The factory does not move the UMA bond itself.
    function escalateToUma(uint256 marketId) external override nonReentrant {
        MarketExtended storage ext = _extendedData[marketId];

        if (ext.escalated) revert AlreadyEscalated();

        // Only escalable post-admin: state must be Cancelled (admin upheld) or Pending (admin
        // rejected) AND we must still be within the 24h cooldown.
        bool inPostResolution =
            (ext.creationStatus == MarketCreationStatus.Cancelled || ext.creationStatus == MarketCreationStatus.Pending)
                && block.timestamp <= ext.resolutionDeadline;
        if (!inPostResolution) {
            revert EscalationWindowClosed();
        }

        // Loser-only standing: pick the eligible escalator from the admin verdict.
        address eligible = ext.creationStatus == MarketCreationStatus.Cancelled
            ? markets[marketId].creator  // admin upheld → creator lost
            : ext.challenger; // admin rejected → challenger lost
        if (msg.sender != eligible) {
            revert NotEligibleToEscalate(msg.sender);
        }

        ext.escalated = true;
        ext.escalator = msg.sender;
        ext.creationStatus = MarketCreationStatus.EscalatedToUma;

        IClovOracleAdapter(oracleAdapter).assertEscalatedChallenge(marketId, ext.challengeReasonHash, msg.sender);

        emit EscalatedToUma(marketId, msg.sender);
    }

    /// @inheritdoc IMarketFactory
    /// @dev Adapter-only callback. Escalator's claim "the admin Layer 1 decision is wrong" was
    ///      upheld by UMA. We finalize the market state machine to the position that reflects
    ///      the escalator's side winning. Layer 1 USDC was already disbursed at admin
    ///      resolution time; the UMA bond (held inside UMA OOV3) is redistributed by UMA itself,
    ///      not by this hook.
    function onEscalationUpheld(uint256 marketId) external override nonReentrant {
        if (msg.sender != oracleAdapter) {
            revert OnlyOracleAdapter(msg.sender);
        }

        MarketExtended storage ext = _extendedData[marketId];
        MarketData storage m = markets[marketId];

        if (ext.escalator == m.creator) {
            // Admin had upheld the challenge (cancelled the market) but UMA reverses that:
            // the creator's market is reinstated to Pending so it can be re-armed/activated.
            ext.creationStatus = MarketCreationStatus.Pending;
            m.status = MarketStatus.Created;
            // Re-arm a short challenge window so the chain state is consistent with a re-opened
            // market, but never shrink an originally-far-future deadline (UMA can resolve faster
            // than the creation-time window expires).
            uint256 reArm = block.timestamp + POST_RESOLUTION_PERIOD;
            if (reArm > ext.challengeDeadline) {
                ext.challengeDeadline = reArm;
            }
            IClovOracleAdapter(oracleAdapter).setPermissionlessAssertion(marketId);
        } else {
            // Admin had rejected the challenge; UMA reverses → market is cancelled.
            ext.creationStatus = MarketCreationStatus.Cancelled;
            m.status = MarketStatus.Cancelled;
            emit MarketCancelled(marketId, ext.challenger);
            emit MarketStatusChanged(marketId, MarketStatus.Cancelled);
        }
    }

    /// @inheritdoc IMarketFactory
    /// @dev Adapter-only callback. UMA rejected the escalation → admin decision stands. We
    ///      restore the market lifecycle state that the admin decision implied (Cancelled or
    ///      Pending) so downstream consumers see a consistent terminal state.
    function onEscalationRejected(uint256 marketId) external override nonReentrant {
        if (msg.sender != oracleAdapter) {
            revert OnlyOracleAdapter(msg.sender);
        }

        MarketExtended storage ext = _extendedData[marketId];
        MarketData storage m = markets[marketId];

        if (ext.escalator == m.creator) {
            // Creator escalated against an admin upheld → admin decision (cancelled) stands.
            ext.creationStatus = MarketCreationStatus.Cancelled;
            m.status = MarketStatus.Cancelled;
        } else {
            // Challenger escalated against an admin rejection → admin decision (pending) stands.
            ext.creationStatus = MarketCreationStatus.Pending;
            // Leave business status alone (still Created); activateMarket can promote later.
            IClovOracleAdapter(oracleAdapter).setPermissionlessAssertion(marketId);
        }
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
    function updateCommunityCreationDeposit(uint256 newDeposit) external override onlyRole(OWNER_ROLE) {
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
