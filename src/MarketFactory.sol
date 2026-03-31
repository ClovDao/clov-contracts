// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IConditionalTokens } from "./interfaces/IConditionalTokens.sol";
import { IFPMMDeterministicFactory } from "./interfaces/IFPMMDeterministicFactory.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";

/// @title MarketFactory
/// @notice Factory contract for creating and managing prediction markets
/// @dev Uses Gnosis Conditional Tokens + FPMM for market mechanics
contract MarketFactory is IMarketFactory, Ownable, Pausable {
    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();

    // ──────────────────────────────────────────────
    // Immutable / External Contracts
    // ──────────────────────────────────────────────

    IERC20 public collateralToken;
    IConditionalTokens public conditionalTokens;
    IFPMMDeterministicFactory public fpmmFactory;

    // ──────────────────────────────────────────────
    // Privileged Addresses
    // ──────────────────────────────────────────────

    address public oracleAdapter;
    address public marketResolver;

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
    // Interface stubs — business logic in future tasks
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketFactory
    function createMarket(
        string calldata,
        uint256,
        Category,
        uint256,
        uint256[] calldata
    ) external override returns (uint256) {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc IMarketFactory
    function pauseMarketCreation() external override {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc IMarketFactory
    function unpauseMarketCreation() external override {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc IMarketFactory
    function updateCreationDeposit(uint256) external override {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc IMarketFactory
    function updateTradingFee(uint256) external override {
        revert("NOT_IMPLEMENTED");
    }

    /// @inheritdoc IMarketFactory
    function getMarket(uint256 marketId) external view override returns (MarketData memory) {
        return markets[marketId];
    }

    /// @inheritdoc IMarketFactory
    function refundCreationDeposit(uint256) external override {
        revert("NOT_IMPLEMENTED");
    }
}
