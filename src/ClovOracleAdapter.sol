// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IClovOracleAdapter } from "./interfaces/IClovOracleAdapter.sol";
import { IOptimisticOracleV3 } from "./interfaces/IOptimisticOracleV3.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";
import { IMarketResolver } from "./interfaces/IMarketResolver.sol";

/// @title ClovOracleAdapter
/// @notice Bridges Clov prediction markets with UMA Optimistic Oracle V3 for outcome resolution
/// @dev Manages assertion lifecycle: assert → UMA callback → resolve via MarketResolver
contract ClovOracleAdapter is IClovOracleAdapter, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error MarketNotActive(uint256 marketId);
    error ResolutionTimestampNotReached(uint256 marketId);
    error MarketAlreadyAsserted(uint256 marketId);
    error OnlyUmaOracle();
    error AssertionNotFound(bytes32 assertionId);
    error AssertionAlreadySettled(bytes32 assertionId);

    // ──────────────────────────────────────────────
    // External Contracts
    // ──────────────────────────────────────────────

    IOptimisticOracleV3 public umaOracle;
    IERC20 public bondToken;
    IMarketFactory public marketFactory;
    IMarketResolver public marketResolver;

    // ──────────────────────────────────────────────
    // Configuration
    // ──────────────────────────────────────────────

    /// @notice Bond amount required for UMA assertions
    uint256 public bondAmount;

    /// @notice Dispute window duration in seconds
    uint64 public assertionLiveness;

    /// @notice UMA identifier for ASSERT_TRUTH
    bytes32 public defaultIdentifier;

    // ──────────────────────────────────────────────
    // Assertion State
    // ──────────────────────────────────────────────

    /// @notice assertionId => Assertion data
    mapping(bytes32 => Assertion) public assertions;

    /// @notice marketId => active assertionId
    mapping(uint256 => bytes32) public marketToAssertion;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _umaOracle,
        address _bondToken,
        address _marketFactory,
        address _marketResolver,
        uint256 _bondAmount,
        uint64 _assertionLiveness
    ) Ownable(msg.sender) {
        if (
            _umaOracle == address(0) || _bondToken == address(0) || _marketFactory == address(0)
                || _marketResolver == address(0)
        ) {
            revert ZeroAddress();
        }

        umaOracle = IOptimisticOracleV3(_umaOracle);
        bondToken = IERC20(_bondToken);
        marketFactory = IMarketFactory(_marketFactory);
        marketResolver = IMarketResolver(_marketResolver);
        bondAmount = _bondAmount;
        assertionLiveness = _assertionLiveness;
        defaultIdentifier = umaOracle.defaultIdentifier();
    }

    // ──────────────────────────────────────────────
    // Assert Outcome
    // ──────────────────────────────────────────────

    /// @inheritdoc IClovOracleAdapter
    function assertOutcome(uint256 marketId, bool outcome, address asserter)
        external
        override
        whenNotPaused
        returns (bytes32)
    {
        IMarketFactory.MarketData memory market = marketFactory.getMarket(marketId);

        // Market must be Active
        if (market.status != IMarketFactory.MarketStatus.Active) {
            revert MarketNotActive(marketId);
        }

        // Resolution timestamp must have passed
        if (block.timestamp < market.resolutionTimestamp) {
            revert ResolutionTimestampNotReached(marketId);
        }

        // No active assertion for this market
        if (marketToAssertion[marketId] != bytes32(0)) {
            revert MarketAlreadyAsserted(marketId);
        }

        // Transfer bond from asserter
        bondToken.safeTransferFrom(asserter, address(this), bondAmount);

        // Approve bond to UMA Oracle
        bondToken.forceApprove(address(umaOracle), bondAmount);

        // Build claim: "Market {marketId} outcome is {YES/NO}"
        bytes memory claim = abi.encodePacked(
            "Market ", _uint256ToString(marketId), " outcome is ", outcome ? "YES" : "NO", " on Clov Protocol."
        );

        // Assert truth on UMA
        bytes32 assertionId = umaOracle.assertTruth(
            claim,
            asserter,
            address(this), // callbackRecipient
            address(0), // no escalation manager
            assertionLiveness,
            bondToken,
            bondAmount,
            defaultIdentifier,
            bytes32(0) // no domain
        );

        // Store assertion
        assertions[assertionId] = Assertion({
            marketId: marketId,
            assertionId: assertionId,
            asserter: asserter,
            outcome: outcome,
            settled: false,
            resolved: false
        });

        marketToAssertion[marketId] = assertionId;

        // Update market status to Resolving
        marketFactory.updateMarketStatus(marketId, IMarketFactory.MarketStatus.Resolving);

        emit OutcomeAsserted(marketId, assertionId, asserter, outcome);

        return assertionId;
    }

    // ──────────────────────────────────────────────
    // UMA Callbacks
    // ──────────────────────────────────────────────

    /// @inheritdoc IClovOracleAdapter
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        if (msg.sender != address(umaOracle)) {
            revert OnlyUmaOracle();
        }

        Assertion storage a = assertions[assertionId];
        if (a.assertionId == bytes32(0)) {
            revert AssertionNotFound(assertionId);
        }

        a.settled = true;

        if (assertedTruthfully) {
            a.resolved = true;

            // Build payouts: [1, 0] if YES won, [0, 1] if NO won
            uint256[] memory payouts = new uint256[](2);
            if (a.outcome) {
                payouts[0] = 1;
                payouts[1] = 0;
            } else {
                payouts[0] = 0;
                payouts[1] = 1;
            }

            // Resolve via MarketResolver
            marketResolver.resolve(a.marketId, payouts);

            emit OutcomeConfirmed(a.marketId, assertionId, a.outcome);
        } else {
            // Assertion was wrong — reset market to Active so a new assertion can be made
            marketToAssertion[a.marketId] = bytes32(0);
            marketFactory.updateMarketStatus(a.marketId, IMarketFactory.MarketStatus.Active);
        }
    }

    /// @inheritdoc IClovOracleAdapter
    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(umaOracle)) {
            revert OnlyUmaOracle();
        }

        Assertion storage a = assertions[assertionId];
        if (a.assertionId == bytes32(0)) {
            revert AssertionNotFound(assertionId);
        }

        // Clear active assertion so a new one can be made after dispute resolves
        marketToAssertion[a.marketId] = bytes32(0);
        marketFactory.updateMarketStatus(a.marketId, IMarketFactory.MarketStatus.Active);

        emit AssertionDisputed(a.marketId, assertionId);
    }

    // ──────────────────────────────────────────────
    // Manual Settlement
    // ──────────────────────────────────────────────

    /// @inheritdoc IClovOracleAdapter
    function settleAndResolve(uint256 marketId) external override {
        bytes32 assertionId = marketToAssertion[marketId];
        if (assertionId == bytes32(0)) {
            revert AssertionNotFound(assertionId);
        }

        Assertion storage a = assertions[assertionId];
        if (a.settled) {
            revert AssertionAlreadySettled(assertionId);
        }

        // This triggers UMA to call assertionResolvedCallback
        umaOracle.settleAssertion(assertionId);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IClovOracleAdapter
    function getAssertion(bytes32 assertionId) external view override returns (Assertion memory) {
        return assertions[assertionId];
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

    // ──────────────────────────────────────────────
    // Internal Helpers
    // ──────────────────────────────────────────────

    /// @dev Converts uint256 to string for claim building
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
