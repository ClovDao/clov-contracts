// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { NegRiskOperator } from "./NegRiskOperator.sol";

/// @notice Minimal surface for NegRiskAdapter.getPositionId used to compute YES/NO token IDs
///         per question at activation time.
interface INegRiskAdapterIds {
    function getPositionId(bytes32 questionId, bool outcome) external view returns (uint256);
    function getConditionId(bytes32 questionId) external view returns (bytes32);
}

/// @notice Minimal surface for NegRiskCtfExchange.registerToken — inherited from the base
///         CTFExchange. The registry must be an admin on the exchange to call this.
interface INegRiskCtfExchangeRegistry {
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId) external;
}

/// @notice Challenge-assertion surface on ClovNegRiskOracle (registry-only).
interface IClovNegRiskOracleChallenge {
    function assertMarketChallenge(bytes32 nrMarketId, bytes32 reasonIpfsHash, address asserter)
        external
        returns (bytes32 assertionId);
}

/// @title NegRiskCommunityRegistry
/// @notice Community-tier incentive layer for NegRisk markets. Mirrors the binary
///         `MarketFactory` Community surface (deposit escrow, 48h challenge window,
///         creator-fee accrual) but keyed by the bytes32 NegRisk market id.
/// @dev    The registry must be added as an admin on `NegRiskOperator` so it can call
///         `clearCommunityPermissionlessAssertion` on challenge or cancel, and on
///         `NegRiskCtfExchange` so `activateMarket` can register per-question tokens.
contract NegRiskCommunityRegistry is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Community-market lifecycle state. Mirrors `IMarketFactory.MarketCreationStatus`.
    enum CreationStatus {
        Pending,
        Active,
        Challenged,
        Cancelled
    }

    struct CommunityQuestion {
        bytes32 questionId;
        bytes32 requestId;
    }

    /// @dev H.3.5 removed `challengerBond` — the bond is held on UMA, not in this contract.
    struct CommunityMarket {
        address creator;
        uint256 createdAt;
        uint256 challengeDeadline;
        uint256 creationDeposit;
        CreationStatus creationStatus;
        address challenger;
        uint256 creatorFeeAccumulated;
    }

    /// @notice Input struct for per-question data during creation.
    struct QuestionInput {
        bytes data;
        bytes32 requestId;
    }

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error MarketAlreadyRegistered(bytes32 nrMarketId);
    error MarketDoesNotExist(bytes32 nrMarketId);
    error NotMarketCreator(bytes32 nrMarketId, address caller);
    error ChallengeWindowClosed();
    error ChallengeWindowStillOpen();
    error AlreadyChallenged();
    error InvalidMarketTransition(CreationStatus from, CreationStatus to);
    error NoCreatorFeeToClaim();
    error NoQuestions();
    error DepositBelowMinimum(uint256 provided, uint256 minimum);
    error DepositAlreadyRefunded(bytes32 nrMarketId);
    error NotRefundable(bytes32 nrMarketId);
    error OnlyOracle(address caller);
    error AlreadyInitialized();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event CommunityMarketCreated(
        bytes32 indexed nrMarketId,
        address indexed creator,
        uint256 challengeDeadline,
        uint256 creationDeposit,
        uint256 questionCount
    );
    event CommunityQuestionRegistered(
        bytes32 indexed nrMarketId, bytes32 indexed questionId, bytes32 indexed requestId
    );
    event MarketChallenged(bytes32 indexed nrMarketId, address indexed challenger, bytes32 reasonIpfsHash);
    event MarketActivated(bytes32 indexed nrMarketId);
    event MarketCancelled(bytes32 indexed nrMarketId, address indexed cancelledBy);
    event CreationDepositRefunded(bytes32 indexed nrMarketId, address indexed creator, uint256 amount);
    event CreatorFeeAccrued(bytes32 indexed nrMarketId, uint256 amount);
    event CreatorFeeClaimed(bytes32 indexed nrMarketId, address indexed creator, uint256 amount);
    event CommunityCreationDepositUpdated(uint256 oldDeposit, uint256 newDeposit);
    event ChallengeUpheld(bytes32 indexed nrMarketId, address indexed challenger, uint256 deposit);
    event ChallengeRejected(bytes32 indexed nrMarketId, uint256 newChallengeDeadline);

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @notice Minimum creation deposit: 1 USDC (6 decimals).
    uint256 public constant MIN_CREATION_DEPOSIT = 1e6;

    /// @notice Challenge window for Community markets: 48 hours from creation.
    uint256 public constant CHALLENGE_PERIOD = 48 hours;

    /// @notice Basis-points denominator (10_000 = 100%). Retained for off-chain callers.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ──────────────────────────────────────────────
    // Immutable
    // ──────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    NegRiskOperator public immutable negRiskOperator;
    INegRiskAdapterIds public immutable negRiskAdapter;
    INegRiskCtfExchangeRegistry public immutable negRiskCtfExchange;

    // ──────────────────────────────────────────────
    // Oracle wiring (one-time)
    // ──────────────────────────────────────────────

    IClovNegRiskOracleChallenge public oracle;

    // ──────────────────────────────────────────────
    // Configuration
    // ──────────────────────────────────────────────

    /// @notice Deposit required to register a Community NegRisk market (default 50 USDC).
    uint256 public communityCreationDeposit = 50e6;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(bytes32 nrMarketId => CommunityMarket) public markets;
    mapping(bytes32 nrMarketId => CommunityQuestion[]) internal _marketQuestions;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _collateralToken,
        address _negRiskOperator,
        address _negRiskAdapter,
        address _negRiskCtfExchange
    ) Ownable(msg.sender) {
        if (
            _collateralToken == address(0) || _negRiskOperator == address(0) || _negRiskAdapter == address(0)
                || _negRiskCtfExchange == address(0)
        ) {
            revert ZeroAddress();
        }
        collateralToken = IERC20(_collateralToken);
        negRiskOperator = NegRiskOperator(_negRiskOperator);
        negRiskAdapter = INegRiskAdapterIds(_negRiskAdapter);
        negRiskCtfExchange = INegRiskCtfExchangeRegistry(_negRiskCtfExchange);
    }

    /// @notice One-time wiring of the ClovNegRiskOracle. Owner-only.
    function setOracle(address _oracle) external onlyOwner {
        if (address(oracle) != address(0)) revert AlreadyInitialized();
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = IClovNegRiskOracleChallenge(_oracle);
    }

    // ──────────────────────────────────────────────
    // Market Creation
    // ──────────────────────────────────────────────

    /// @notice Create and register a Community NegRisk market. Permissionless. Caller escrows
    ///         `communityCreationDeposit` USDC, opens a 48h challenge window, and is flagged as
    ///         the creator for fee-share purposes.
    /// @param feeBips       market fee rate (bps) passed to the NegRiskAdapter
    /// @param marketData    market metadata passed to the NegRiskAdapter
    /// @param questions     per-question data + oracle request IDs
    /// @return nrMarketId   the NegRisk market id returned by the adapter
    function createCommunityMarket(uint256 feeBips, bytes calldata marketData, QuestionInput[] calldata questions)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 nrMarketId)
    {
        if (questions.length == 0) revert NoQuestions();

        uint256 deposit = communityCreationDeposit;
        collateralToken.safeTransferFrom(msg.sender, address(this), deposit);

        nrMarketId = negRiskOperator.prepareCommunityMarket(feeBips, marketData);

        if (markets[nrMarketId].creator != address(0)) revert MarketAlreadyRegistered(nrMarketId);

        uint256 deadline = block.timestamp + CHALLENGE_PERIOD;
        markets[nrMarketId] = CommunityMarket({
            creator: msg.sender,
            createdAt: block.timestamp,
            challengeDeadline: deadline,
            creationDeposit: deposit,
            creationStatus: CreationStatus.Pending,
            challenger: address(0),
            creatorFeeAccumulated: 0
        });

        uint256 qLen = questions.length;
        for (uint256 i; i < qLen; ++i) {
            bytes32 questionId =
                negRiskOperator.prepareCommunityQuestion(nrMarketId, questions[i].data, questions[i].requestId);
            _marketQuestions[nrMarketId].push(
                CommunityQuestion({ questionId: questionId, requestId: questions[i].requestId })
            );
            emit CommunityQuestionRegistered(nrMarketId, questionId, questions[i].requestId);
        }

        emit CommunityMarketCreated(nrMarketId, msg.sender, deadline, deposit, qLen);
    }

    // ──────────────────────────────────────────────
    // Challenge / Activate / Cancel
    // ──────────────────────────────────────────────

    /// @notice Challenge a Pending Community market within the 48h window. The challenger's bond
    ///         is pulled by the oracle and escrowed on UMA — no bond is held in this contract.
    ///         Clears the permissionless-assertion flag on every question so dispute routing
    ///         goes through the allowlisted path.
    /// @param nrMarketId      The NegRisk market id being challenged.
    /// @param reasonIpfsHash  IPFS digest of the off-chain evidence bundle.
    function challengeMarket(bytes32 nrMarketId, bytes32 reasonIpfsHash) external nonReentrant {
        CommunityMarket storage m = markets[nrMarketId];
        if (m.creator == address(0)) revert MarketDoesNotExist(nrMarketId);
        if (m.creationStatus == CreationStatus.Challenged) revert AlreadyChallenged();
        if (m.creationStatus != CreationStatus.Pending) {
            revert InvalidMarketTransition(m.creationStatus, CreationStatus.Challenged);
        }
        if (block.timestamp > m.challengeDeadline) revert ChallengeWindowClosed();

        m.creationStatus = CreationStatus.Challenged;
        m.challenger = msg.sender;

        _revokePermissionlessAssertions(nrMarketId);

        oracle.assertMarketChallenge(nrMarketId, reasonIpfsHash, msg.sender);

        emit MarketChallenged(nrMarketId, msg.sender, reasonIpfsHash);
    }

    /// @notice Activate a Pending Community market whose 48h window closed without dispute.
    ///         Permissionless. Transitions Pending -> Active and registers YES/NO tokenIds
    ///         for every question on NegRiskCtfExchange.
    function activateMarket(bytes32 nrMarketId) external {
        CommunityMarket storage m = markets[nrMarketId];
        if (m.creator == address(0)) revert MarketDoesNotExist(nrMarketId);
        if (m.creationStatus != CreationStatus.Pending) {
            revert InvalidMarketTransition(m.creationStatus, CreationStatus.Active);
        }
        if (block.timestamp <= m.challengeDeadline) revert ChallengeWindowStillOpen();

        m.creationStatus = CreationStatus.Active;

        CommunityQuestion[] storage qs = _marketQuestions[nrMarketId];
        uint256 qLen = qs.length;
        for (uint256 i; i < qLen; ++i) {
            bytes32 questionId = qs[i].questionId;
            uint256 yesId = negRiskAdapter.getPositionId(questionId, true);
            uint256 noId = negRiskAdapter.getPositionId(questionId, false);
            bytes32 conditionId = negRiskAdapter.getConditionId(questionId);
            negRiskCtfExchange.registerToken(yesId, noId, conditionId);
        }

        emit MarketActivated(nrMarketId);
    }

    /// @notice Emergency cancel — admin only. Clears permissionless flags if cancel happens
    ///         while the market is still Pending (pre-activation). Forbidden while a UMA
    ///         challenge is in flight: cancelling a Challenged market would leave the
    ///         creationDeposit claimable by the creator via refundCreationDeposit, robbing
    ///         the challenger of their reward. Admin must wait for UMA resolution.
    function cancelMarket(bytes32 nrMarketId) external onlyOwner {
        CommunityMarket storage m = markets[nrMarketId];
        if (m.creator == address(0)) revert MarketDoesNotExist(nrMarketId);
        if (m.creationStatus == CreationStatus.Cancelled || m.creationStatus == CreationStatus.Challenged) {
            revert InvalidMarketTransition(m.creationStatus, CreationStatus.Cancelled);
        }

        CreationStatus prev = m.creationStatus;
        m.creationStatus = CreationStatus.Cancelled;

        if (prev == CreationStatus.Pending) {
            _revokePermissionlessAssertions(nrMarketId);
        }

        emit MarketCancelled(nrMarketId, msg.sender);
    }

    // ──────────────────────────────────────────────
    // Oracle Callbacks (H.3.5)
    // ──────────────────────────────────────────────

    /// @notice Oracle-only callback: UMA upheld the challenge. Deposit routes to the challenger,
    ///         market becomes Cancelled.
    function onChallengeUpheld(bytes32 nrMarketId) external nonReentrant {
        if (msg.sender != address(oracle)) revert OnlyOracle(msg.sender);

        CommunityMarket storage m = markets[nrMarketId];
        address challenger = m.challenger;
        uint256 deposit = m.creationDeposit;

        m.creationStatus = CreationStatus.Cancelled;
        m.creationDeposit = 0;

        if (deposit > 0 && challenger != address(0)) {
            collateralToken.safeTransfer(challenger, deposit);
        }

        emit ChallengeUpheld(nrMarketId, challenger, deposit);
        emit MarketCancelled(nrMarketId, challenger);
    }

    /// @notice Oracle-only callback: UMA rejected the challenge. Returns the market to Pending
    ///         with an extended 48h challenge window and re-enables permissionless asserting.
    function onChallengeRejected(bytes32 nrMarketId) external nonReentrant {
        if (msg.sender != address(oracle)) revert OnlyOracle(msg.sender);

        CommunityMarket storage m = markets[nrMarketId];
        m.creationStatus = CreationStatus.Pending;
        m.challenger = address(0);

        uint256 newDeadline = block.timestamp + CHALLENGE_PERIOD;
        m.challengeDeadline = newDeadline;

        _restorePermissionlessAssertions(nrMarketId);

        emit ChallengeRejected(nrMarketId, newDeadline);
    }

    // ──────────────────────────────────────────────
    // Creator Fee Accrual / Claim
    // ──────────────────────────────────────────────

    /// @notice Pull-transfer USDC into the creator-fee bucket for a Community market.
    function accrueCreatorFee(bytes32 nrMarketId, uint256 amount) external nonReentrant {
        CommunityMarket storage m = markets[nrMarketId];
        if (m.creator == address(0)) revert MarketDoesNotExist(nrMarketId);

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        m.creatorFeeAccumulated += amount;

        emit CreatorFeeAccrued(nrMarketId, amount);
    }

    /// @notice Withdraw accumulated creator fees. Only callable by the market creator.
    function claimCreatorFee(bytes32 nrMarketId) external nonReentrant {
        CommunityMarket storage m = markets[nrMarketId];
        if (m.creator == address(0)) revert MarketDoesNotExist(nrMarketId);
        if (msg.sender != m.creator) revert NotMarketCreator(nrMarketId, msg.sender);

        uint256 amount = m.creatorFeeAccumulated;
        if (amount == 0) revert NoCreatorFeeToClaim();

        m.creatorFeeAccumulated = 0;
        collateralToken.safeTransfer(m.creator, amount);

        emit CreatorFeeClaimed(nrMarketId, m.creator, amount);
    }

    // ──────────────────────────────────────────────
    // Refund
    // ──────────────────────────────────────────────

    /// @notice Refund the creation deposit after cancel. Only callable by the creator and only
    ///         when the market is in the Cancelled state.
    function refundCreationDeposit(bytes32 nrMarketId) external nonReentrant {
        CommunityMarket storage m = markets[nrMarketId];
        if (m.creator == address(0)) revert MarketDoesNotExist(nrMarketId);
        if (msg.sender != m.creator) revert NotMarketCreator(nrMarketId, msg.sender);
        if (m.creationStatus != CreationStatus.Cancelled) revert NotRefundable(nrMarketId);
        if (m.creationDeposit == 0) revert DepositAlreadyRefunded(nrMarketId);

        uint256 amount = m.creationDeposit;
        m.creationDeposit = 0;

        collateralToken.safeTransfer(m.creator, amount);
        emit CreationDepositRefunded(nrMarketId, m.creator, amount);
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function pauseMarketCreation() external onlyOwner {
        _pause();
    }

    function unpauseMarketCreation() external onlyOwner {
        _unpause();
    }

    function updateCommunityCreationDeposit(uint256 newDeposit) external onlyOwner {
        if (newDeposit < MIN_CREATION_DEPOSIT) revert DepositBelowMinimum(newDeposit, MIN_CREATION_DEPOSIT);
        uint256 old = communityCreationDeposit;
        communityCreationDeposit = newDeposit;
        emit CommunityCreationDepositUpdated(old, newDeposit);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function getMarket(bytes32 nrMarketId) external view returns (CommunityMarket memory) {
        return markets[nrMarketId];
    }

    function getMarketQuestions(bytes32 nrMarketId) external view returns (CommunityQuestion[] memory) {
        return _marketQuestions[nrMarketId];
    }

    function getMarketQuestionCount(bytes32 nrMarketId) external view returns (uint256) {
        return _marketQuestions[nrMarketId].length;
    }

    /// @notice Returns true iff the nrMarketId is registered Community-tier AND currently Active
    ///         (challenge window closed, no unresolved dispute). Consumed by
    ///         `ClovCommunityExecutor` to gate community-only fee distribution.
    function isCommunityMarket(bytes32 nrMarketId) external view returns (bool) {
        CommunityMarket storage m = markets[nrMarketId];
        return m.creator != address(0) && m.creationStatus == CreationStatus.Active;
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    /// @dev Loop through registered questions and clear the permissionless flag on each.
    ///      Requires this registry to be an admin on the NegRiskOperator.
    function _revokePermissionlessAssertions(bytes32 nrMarketId) internal {
        CommunityQuestion[] storage qs = _marketQuestions[nrMarketId];
        uint256 qLen = qs.length;
        for (uint256 i; i < qLen; ++i) {
            negRiskOperator.clearCommunityPermissionlessAssertion(qs[i].requestId);
        }
    }

    /// @dev Re-enable permissionless asserting on every question after a rejected challenge.
    function _restorePermissionlessAssertions(bytes32 nrMarketId) internal {
        CommunityQuestion[] storage qs = _marketQuestions[nrMarketId];
        uint256 qLen = qs.length;
        for (uint256 i; i < qLen; ++i) {
            negRiskOperator.setCommunityPermissionlessAssertion(qs[i].requestId);
        }
    }
}
