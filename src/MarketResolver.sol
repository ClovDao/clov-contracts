// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IMarketResolver } from "./interfaces/IMarketResolver.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";
import { IConditionalTokens } from "./interfaces/IConditionalTokens.sol";

/// @title MarketResolver
/// @notice Resolves prediction markets by reporting payouts to Gnosis Conditional Tokens
/// @dev Only callable by ClovOracleAdapter after UMA confirms the outcome
contract MarketResolver is IMarketResolver, Ownable, Pausable {
    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error OnlyOracleAdapter();
    error MarketAlreadyResolved(uint256 marketId);
    error AlreadyInitialized();

    // ──────────────────────────────────────────────
    // External Contracts
    // ──────────────────────────────────────────────

    IConditionalTokens public immutable conditionalTokens;

    // ──────────────────────────────────────────────
    // Cross-references (set post-deploy via initialize)
    // ──────────────────────────────────────────────

    IMarketFactory public marketFactory;
    address public oracleAdapter;

    // ──────────────────────────────────────────────
    // Resolution State
    // ──────────────────────────────────────────────

    /// @notice marketId => resolved flag
    mapping(uint256 => bool) public isResolved;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address _conditionalTokens) Ownable(msg.sender) {
        if (_conditionalTokens == address(0)) {
            revert ZeroAddress();
        }

        conditionalTokens = IConditionalTokens(_conditionalTokens);
    }

    /// @notice One-time initialization of cross-references (resolves circular dependency)
    /// @param _marketFactory Address of the MarketFactory
    /// @param _oracleAdapter Address of the ClovOracleAdapter
    function initialize(address _marketFactory, address _oracleAdapter) external onlyOwner {
        if (address(marketFactory) != address(0) || oracleAdapter != address(0)) {
            revert AlreadyInitialized();
        }
        if (_marketFactory == address(0) || _oracleAdapter == address(0)) {
            revert ZeroAddress();
        }
        marketFactory = IMarketFactory(_marketFactory);
        oracleAdapter = _oracleAdapter;
    }

    // ──────────────────────────────────────────────
    // Resolution
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketResolver
    function resolve(uint256 marketId, uint256[] calldata payouts) external override {
        if (msg.sender != oracleAdapter) {
            revert OnlyOracleAdapter();
        }
        if (isResolved[marketId]) {
            revert MarketAlreadyResolved(marketId);
        }

        // Get market data for the questionId
        IMarketFactory.MarketData memory market = marketFactory.getMarket(marketId);

        // Mark as resolved
        isResolved[marketId] = true;

        // Report payouts to Gnosis Conditional Tokens
        conditionalTokens.reportPayouts(market.questionId, payouts);

        // Update market status to Resolved
        marketFactory.updateMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        emit MarketResolved(marketId, payouts);
    }

    /// @inheritdoc IMarketResolver
    function isMarketResolved(uint256 marketId) external view override returns (bool) {
        return isResolved[marketId];
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
