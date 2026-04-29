// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IClovOracleAdapter } from "./interfaces/IClovOracleAdapter.sol";
import { IOptimisticOracleV3 } from "./interfaces/IOptimisticOracleV3.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";
import { IMarketResolver } from "./interfaces/IMarketResolver.sol";

/// @title ClovOracleAdapter
/// @notice Bridges Clov prediction markets with UMA Optimistic Oracle V3 for outcome resolution
///         and Community-market Layer 2 escalation disputes.
/// @dev    Manages two assertion lifecycles:
///         - **Outcome** assertions: `assertOutcome` → UMA → `assertionResolvedCallback` → resolver.
///         - **Escalation** assertions: `assertEscalatedChallenge` (factory-only) → UMA → callback
///           routes into `MarketFactory.onEscalationUpheld / onEscalationRejected`.
///         The Layer 1 challenge flow is escrowed inside `MarketFactory` and never touches UMA.
contract ClovOracleAdapter is IClovOracleAdapter, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    /// @notice Owner role: tunes bond amounts, manages asserter allowlist, pauses.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

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
    error AlreadyInitialized();

    /// @notice Thrown when a non-allowlisted address attempts to assert an outcome
    error UnauthorizedAsserter(address caller);

    /// @notice Thrown when a non-MarketFactory caller tries to mutate per-market flags
    ///         or open an escalation assertion.
    error OnlyMarketFactory(address caller);

    /// @notice Thrown when an escalation is requested for a market that already has a live one.
    error EscalationAlreadyAsserted(uint256 marketId);

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when an asserter is added to the allowlist
    event AsserterAdded(address indexed asserter);

    /// @notice Emitted when an asserter is removed from the allowlist
    event AsserterRemoved(address indexed asserter);

    // ──────────────────────────────────────────────
    // External Contracts
    // ──────────────────────────────────────────────

    IOptimisticOracleV3 public immutable umaOracle;
    IERC20 public immutable bondToken;

    // ──────────────────────────────────────────────
    // Cross-references (set post-deploy via initialize)
    // ──────────────────────────────────────────────

    IMarketFactory public marketFactory;
    IMarketResolver public marketResolver;

    // ──────────────────────────────────────────────
    // Configuration
    // ──────────────────────────────────────────────

    /// @notice Bond amount required for UMA outcome and escalation assertions. Owner-tunable.
    uint256 public bondAmount;

    /// @notice Dispute window duration in seconds
    uint64 public immutable assertionLiveness;

    /// @notice UMA identifier for ASSERT_TRUTH
    bytes32 public immutable defaultIdentifier;

    // ──────────────────────────────────────────────
    // Assertion State
    // ──────────────────────────────────────────────

    /// @notice assertionId => Assertion data (outcome assertions)
    mapping(bytes32 => Assertion) public assertions;

    /// @notice marketId => active outcome assertionId
    mapping(uint256 => bytes32) public marketToAssertion;

    /// @notice assertionId => marketId for Community-market Layer 2 escalation assertions.
    ///         Lets `assertionResolvedCallback` branch between outcome and escalation paths.
    /// @dev    Read with `isEscalationAssertion` to disambiguate marketId==0 from "not an escalation".
    mapping(bytes32 => uint256) public escalationAssertions;

    /// @notice assertionId => true if this is an escalation assertion (vs outcome).
    mapping(bytes32 => bool) public isEscalationAssertion;

    /// @notice marketId => active escalation assertionId (bytes32(0) when none in flight).
    mapping(uint256 => bytes32) public marketToEscalationAssertion;

    /// @notice Tracks addresses allowed to call assertOutcome
    mapping(address => bool) public allowedAsserters;

    /// @notice Per-market flag. When true, assertOutcome bypasses the allowedAsserters
    ///         allowlist for that market (Community tier). Set/cleared by the MarketFactory.
    mapping(uint256 => bool) private _permissionlessAssertion;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address _umaOracle, address _bondToken, uint256 _bondAmount, uint64 _assertionLiveness) {
        if (_umaOracle == address(0) || _bondToken == address(0)) {
            revert ZeroAddress();
        }

        umaOracle = IOptimisticOracleV3(_umaOracle);
        bondToken = IERC20(_bondToken);
        bondAmount = _bondAmount;
        assertionLiveness = _assertionLiveness;
        defaultIdentifier = umaOracle.defaultIdentifier();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OWNER_ROLE, msg.sender);
    }

    /// @notice One-time initialization of cross-references (resolves circular dependency)
    /// @param _marketFactory Address of the MarketFactory
    /// @param _marketResolver Address of the MarketResolver
    function initialize(address _marketFactory, address _marketResolver) external onlyRole(OWNER_ROLE) {
        if (address(marketFactory) != address(0) || address(marketResolver) != address(0)) {
            revert AlreadyInitialized();
        }
        if (_marketFactory == address(0) || _marketResolver == address(0)) {
            revert ZeroAddress();
        }
        marketFactory = IMarketFactory(_marketFactory);
        marketResolver = IMarketResolver(_marketResolver);

        // Owner is an asserter by default
        allowedAsserters[msg.sender] = true;
        emit AsserterAdded(msg.sender);
    }

    // ──────────────────────────────────────────────
    // Assert Outcome
    // ──────────────────────────────────────────────

    /// @inheritdoc IClovOracleAdapter
    function assertOutcome(uint256 marketId, bool outcome, address asserter)
        external
        override
        whenNotPaused
        nonReentrant
        returns (bytes32)
    {
        if (!allowedAsserters[msg.sender] && !_permissionlessAssertion[marketId]) {
            revert UnauthorizedAsserter(msg.sender);
        }

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
    // Layer 2 Escalation
    // ──────────────────────────────────────────────

    /// @inheritdoc IClovOracleAdapter
    /// @dev Only callable by the MarketFactory. Pulls `bondAmount` USDC from `asserter`
    ///      (the escalator) and opens a UMA assertion claiming the admin Layer 1 decision
    ///      should be overturned. The UMA callback resolves back into the factory via
    ///      `onEscalationUpheld` / `onEscalationRejected`.
    function assertEscalatedChallenge(uint256 marketId, bytes32 reasonHash, address asserter)
        external
        override
        whenNotPaused
        nonReentrant
        returns (bytes32)
    {
        if (msg.sender != address(marketFactory)) {
            revert OnlyMarketFactory(msg.sender);
        }
        if (marketToEscalationAssertion[marketId] != bytes32(0)) {
            revert EscalationAlreadyAsserted(marketId);
        }

        bondToken.safeTransferFrom(asserter, address(this), bondAmount);
        bondToken.forceApprove(address(umaOracle), bondAmount);

        bytes memory claim = abi.encodePacked(
            "Community market ",
            _uint256ToString(marketId),
            " admin Layer 1 decision overturned per ipfs://",
            _bytes32ToHex(reasonHash)
        );

        bytes32 assertionId = umaOracle.assertTruth(
            claim,
            asserter,
            address(this),
            address(0),
            assertionLiveness,
            bondToken,
            bondAmount,
            defaultIdentifier,
            bytes32(0)
        );

        escalationAssertions[assertionId] = marketId;
        isEscalationAssertion[assertionId] = true;
        marketToEscalationAssertion[marketId] = assertionId;

        emit EscalationAsserted(marketId, assertionId, asserter, reasonHash);

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

        // Branch: escalation assertion routes back into the factory.
        if (isEscalationAssertion[assertionId]) {
            uint256 marketId = escalationAssertions[assertionId];
            // Clear state before external call to prevent re-entrant mischief.
            delete escalationAssertions[assertionId];
            delete isEscalationAssertion[assertionId];
            delete marketToEscalationAssertion[marketId];

            if (assertedTruthfully) {
                marketFactory.onEscalationUpheld(marketId);
            } else {
                marketFactory.onEscalationRejected(marketId);
            }
            return;
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

        // Escalation assertion disputed — no factory state change here; the final
        // truth/false decision still flows through assertionResolvedCallback.
        if (isEscalationAssertion[assertionId]) {
            return;
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

    /// @notice Adds an address to the asserter allowlist
    /// @param asserter The address to allowlist
    function addAsserter(address asserter) external onlyRole(OWNER_ROLE) {
        if (asserter == address(0)) revert ZeroAddress();
        allowedAsserters[asserter] = true;
        emit AsserterAdded(asserter);
    }

    /// @notice Removes an address from the asserter allowlist
    /// @param asserter The address to remove
    function removeAsserter(address asserter) external onlyRole(OWNER_ROLE) {
        if (asserter == address(0)) revert ZeroAddress();
        allowedAsserters[asserter] = false;
        emit AsserterRemoved(asserter);
    }

    /// @inheritdoc IClovOracleAdapter
    function setBondAmount(uint256 newBond) external override onlyRole(OWNER_ROLE) {
        uint256 old = bondAmount;
        bondAmount = newBond;
        emit BondAmountUpdated(old, newBond);
    }

    /// @inheritdoc IClovOracleAdapter
    /// @dev Only the registered MarketFactory may flag a market as permissionless-assertable.
    ///      Called on Community market creation so outcome assertions bypass the allowlist.
    function setPermissionlessAssertion(uint256 marketId) external override {
        if (msg.sender != address(marketFactory)) {
            revert OnlyMarketFactory(msg.sender);
        }
        _permissionlessAssertion[marketId] = true;
        emit PermissionlessAssertionSet(marketId);
    }

    /// @inheritdoc IClovOracleAdapter
    /// @dev Only the registered MarketFactory may clear the flag. Called on challenge or cancel
    ///      so a dispute can be resolved through the regular allowlist path.
    function clearPermissionlessAssertion(uint256 marketId) external override {
        if (msg.sender != address(marketFactory)) {
            revert OnlyMarketFactory(msg.sender);
        }
        _permissionlessAssertion[marketId] = false;
        emit PermissionlessAssertionCleared(marketId);
    }

    /// @inheritdoc IClovOracleAdapter
    function isPermissionlessAssertion(uint256 marketId) external view override returns (bool) {
        return _permissionlessAssertion[marketId];
    }

    function pause() external onlyRole(OWNER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(OWNER_ROLE) {
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

    /// @dev Hex-encodes a bytes32 as a 64-char ASCII string for claim building.
    function _bytes32ToHex(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = alphabet[uint8(value[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
