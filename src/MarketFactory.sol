// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IConditionalTokens } from "./interfaces/IConditionalTokens.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";

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

    // ──────────────────────────────────────────────
    // Immutable / External Contracts
    // ──────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    IConditionalTokens public immutable conditionalTokens;

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

    // ──────────────────────────────────────────────
    // Market State
    // ──────────────────────────────────────────────

    /// @notice Auto-increment market ID counter
    uint256 public marketCount;

    /// @notice marketId => MarketData
    mapping(uint256 => MarketData) public markets;

    /// @notice questionId => marketId (reverse lookup)
    mapping(bytes32 => uint256) public questionIdToMarketId;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _collateralToken,
        address _conditionalTokens,
        uint256 _creationDeposit
    ) Ownable(msg.sender) {
        if (_collateralToken == address(0) || _conditionalTokens == address(0)) {
            revert ZeroAddress();
        }

        if (_creationDeposit < MIN_CREATION_DEPOSIT) {
            revert DepositBelowMinimum(_creationDeposit, MIN_CREATION_DEPOSIT);
        }

        collateralToken = IERC20(_collateralToken);
        conditionalTokens = IConditionalTokens(_conditionalTokens);
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
    /// @dev Front-running vector: a griefing actor could observe a pending createMarket tx and
    ///      front-run it with an identical market. This is low risk on Polygon (2 s blocks reduce
    ///      the mempool window) and economically disincentivized by the creationDeposit bond, which
    ///      the front-runner would forfeit if their copycat market is not legitimately resolved.
    function createMarket(
        string calldata metadataURI,
        uint256 resolutionTimestamp,
        Category category
    ) external override whenNotPaused nonReentrant returns (uint256) {
        // 1. Validate resolution timestamp (must be at least 1 hour in the future)
        if (resolutionTimestamp <= block.timestamp + 1 hours) {
            revert InvalidResolutionTimestamp();
        }

        // 2. Transfer creationDeposit from msg.sender (anti-spam bond)
        collateralToken.safeTransferFrom(msg.sender, address(this), creationDeposit);

        // 3. Generate questionId (includes block.chainid and address(this) to prevent cross-chain/cross-deployment collisions)
        bytes32 questionId = keccak256(abi.encodePacked(block.chainid, address(this), marketCount, msg.sender, block.timestamp));

        // 4. Prepare condition on ConditionalTokens (binary outcome = 2)
        conditionalTokens.prepareCondition(marketResolver, questionId, 2);

        // 5. Get conditionId
        bytes32 conditionId = conditionalTokens.getConditionId(marketResolver, questionId, 2);

        // 6. Store MarketData
        uint256 marketId = marketCount;

        markets[marketId] = MarketData({
            questionId: questionId,
            conditionId: conditionId,
            creator: msg.sender,
            metadataURI: metadataURI,
            creationDeposit: creationDeposit,
            resolutionTimestamp: resolutionTimestamp,
            status: MarketStatus.Active,
            category: category
        });

        // 7. Store reverse lookup
        questionIdToMarketId[questionId] = marketId;

        // 8. Increment marketCount
        marketCount++;

        // 9. Emit event
        emit MarketCreated(
            marketId,
            msg.sender,
            conditionId,
            questionId,
            metadataURI,
            resolutionTimestamp,
            category
        );

        return marketId;
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

        MarketStatus currentStatus = m.status;
        if (!_isValidTransition(currentStatus, MarketStatus.Cancelled)) {
            revert InvalidStateTransition(currentStatus, MarketStatus.Cancelled);
        }

        m.status = MarketStatus.Cancelled;

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
    function _isValidTransition(MarketStatus currentStatus, MarketStatus newStatus)
        internal
        pure
        returns (bool valid)
    {
        // Created → Active
        if (currentStatus == MarketStatus.Created && newStatus == MarketStatus.Active) return true;
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
}
