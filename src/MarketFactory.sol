// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IConditionalTokens } from "./interfaces/IConditionalTokens.sol";
import { IFPMMDeterministicFactory } from "./interfaces/IFPMMDeterministicFactory.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";

/// @title MarketFactory
/// @notice Factory contract for creating and managing prediction markets
/// @dev Uses Gnosis Conditional Tokens + FPMM for market mechanics
contract MarketFactory is IMarketFactory, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error InvalidResolutionTimestamp();
    error InsufficientInitialLiquidity();
    error MarketNotResolved(uint256 marketId);
    error NotMarketCreator(uint256 marketId, address caller);
    error DepositAlreadyRefunded(uint256 marketId);
    error InvalidTradingFee(uint256 fee, uint256 maxFee);
    error UnauthorizedStatusUpdate(address caller);

    /// @notice Maximum trading fee: 10% (1000 basis points)
    uint256 public constant MAX_TRADING_FEE = 1000;

    // ──────────────────────────────────────────────
    // Immutable / External Contracts
    // ──────────────────────────────────────────────

    IERC20 public immutable collateralToken;
    IConditionalTokens public immutable conditionalTokens;
    IFPMMDeterministicFactory public immutable fpmmFactory;

    // ──────────────────────────────────────────────
    // Privileged Addresses
    // ──────────────────────────────────────────────

    address public immutable oracleAdapter;
    address public immutable marketResolver;

    // ──────────────────────────────────────────────
    // Configuration
    // ──────────────────────────────────────────────

    /// @notice Anti-spam deposit required to create a market (in collateral token units)
    uint256 public creationDeposit;

    /// @notice Trading fee for FPMM in basis points (e.g. 100 = 1%)
    uint256 public tradingFee;

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
        address _fpmmFactory,
        address _oracleAdapter,
        address _marketResolver,
        uint256 _creationDeposit,
        uint256 _tradingFee
    ) Ownable(msg.sender) {
        if (
            _collateralToken == address(0) || _conditionalTokens == address(0) || _fpmmFactory == address(0)
                || _oracleAdapter == address(0) || _marketResolver == address(0)
        ) {
            revert ZeroAddress();
        }

        collateralToken = IERC20(_collateralToken);
        conditionalTokens = IConditionalTokens(_conditionalTokens);
        fpmmFactory = IFPMMDeterministicFactory(_fpmmFactory);
        oracleAdapter = _oracleAdapter;
        marketResolver = _marketResolver;
        creationDeposit = _creationDeposit;
        tradingFee = _tradingFee;
    }

    // ──────────────────────────────────────────────
    // Market Creation
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    function createMarket(
        string calldata metadataURI,
        uint256 resolutionTimestamp,
        Category category,
        uint256 initialLiquidity,
        uint256[] calldata initialOdds
    ) external override whenNotPaused nonReentrant returns (uint256) {
        // 1. Validate resolution timestamp (must be at least 1 hour in the future)
        if (resolutionTimestamp <= block.timestamp + 1 hours) {
            revert InvalidResolutionTimestamp();
        }

        // 2. Validate initial liquidity
        if (initialLiquidity == 0) {
            revert InsufficientInitialLiquidity();
        }

        // 3. Transfer creationDeposit + initialLiquidity from msg.sender
        collateralToken.safeTransferFrom(msg.sender, address(this), creationDeposit + initialLiquidity);

        // 4. Generate questionId
        bytes32 questionId = keccak256(abi.encodePacked(marketCount, msg.sender, block.timestamp));

        // 5. Prepare condition on ConditionalTokens (binary outcome = 2)
        conditionalTokens.prepareCondition(marketResolver, questionId, 2);

        // 6. Get conditionId
        bytes32 conditionId = conditionalTokens.getConditionId(marketResolver, questionId, 2);

        // 7. Approve collateralToken to fpmmFactory for initialLiquidity
        collateralToken.forceApprove(address(fpmmFactory), initialLiquidity);

        // 8. Build conditionIds array and create FPMM
        address fpmm;
        {
            bytes32[] memory conditionIds = new bytes32[](1);
            conditionIds[0] = conditionId;

            fpmm = fpmmFactory.create2FixedProductMarketMaker(
                conditionalTokens,
                collateralToken,
                conditionIds,
                tradingFee,
                initialLiquidity,
                initialOdds
            );
        }

        // 9. Store MarketData
        uint256 marketId = marketCount;

        markets[marketId] = MarketData({
            questionId: questionId,
            conditionId: conditionId,
            fpmm: fpmm,
            creator: msg.sender,
            metadataURI: metadataURI,
            creationDeposit: creationDeposit,
            resolutionTimestamp: resolutionTimestamp,
            status: MarketStatus.Active,
            category: category
        });

        // 10. Store reverse lookup
        questionIdToMarketId[questionId] = marketId;

        // 11. Increment marketCount
        marketCount++;

        // 12. Emit event (read from storage to reduce stack depth)
        _emitMarketCreated(marketId, initialLiquidity);

        // 13. Return marketId
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
        uint256 oldDeposit = creationDeposit;
        creationDeposit = newDeposit;
        emit CreationDepositUpdated(oldDeposit, newDeposit);
    }

    /// @inheritdoc IMarketFactory
    function updateTradingFee(uint256 newFee) external override onlyOwner {
        if (newFee > MAX_TRADING_FEE) {
            revert InvalidTradingFee(newFee, MAX_TRADING_FEE);
        }
        uint256 oldFee = tradingFee;
        tradingFee = newFee;
        emit TradingFeeUpdated(oldFee, newFee);
    }

    /// @inheritdoc IMarketFactory
    function updateMarketStatus(uint256 marketId, MarketStatus newStatus) external override {
        if (msg.sender != oracleAdapter && msg.sender != marketResolver) {
            revert UnauthorizedStatusUpdate(msg.sender);
        }
        markets[marketId].status = newStatus;
        emit MarketStatusChanged(marketId, newStatus);
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
    function refundCreationDeposit(uint256 marketId) external override {
        MarketData storage m = markets[marketId];

        if (m.status != MarketStatus.Resolved) {
            revert MarketNotResolved(marketId);
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

    /// @dev Emits MarketCreated event reading from storage to avoid stack-too-deep
    function _emitMarketCreated(uint256 marketId, uint256 initialLiquidity) internal {
        MarketData storage m = markets[marketId];
        emit MarketCreated(
            marketId,
            m.creator,
            m.fpmm,
            m.conditionId,
            m.questionId,
            m.metadataURI,
            m.resolutionTimestamp,
            m.category,
            initialLiquidity
        );
    }
}
