// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IOptimisticOracleV3 } from "../interfaces/IOptimisticOracleV3.sol";

/// @title IClovNegRiskOracle
/// @notice Interface for the NegRisk operator's oracle expectations
interface INegRiskOperatorOracle {
    function reportPayouts(bytes32 requestId, uint256[] calldata payouts) external;
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
}

/// @notice Callback surface the NegRiskCommunityRegistry exposes to the oracle so challenge
///         outcomes can be routed back into its market lifecycle.
interface INegRiskCommunityRegistryCallback {
    function onChallengeUpheld(bytes32 nrMarketId) external;
    function onChallengeRejected(bytes32 nrMarketId) external;
}

/// @title ClovNegRiskOracle
/// @notice Bridges UMA OOV3 with NegRiskOperator for categorical market resolution
/// @dev Each NegRisk question gets its own UMA assertion for outcome resolution. Community
///      markets have a *single* challenge assertion at the nrMarketId level (H.3.5): one
///      "this whole market is invalid" dispute, not one per question.
contract ClovNegRiskOracle is Ownable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error OnlyUmaOracle();
    error QuestionAlreadyAsserted(bytes32 requestId);
    error AssertionNotFound(bytes32 assertionId);
    error AssertionAlreadySettled(bytes32 assertionId);
    error UnauthorizedAsserter(address caller);

    /// @notice Thrown when a non-NegRiskOperator caller tries to mutate per-question flags.
    error OnlyNegRiskOperator(address caller);

    /// @notice Thrown when a non-registry caller tries to open a challenge assertion or
    ///         when the registry address has not been wired.
    error OnlyRegistry(address caller);

    error ChallengeAlreadyAsserted(bytes32 nrMarketId);
    error AlreadyInitialized();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event QuestionAsserted(bytes32 indexed requestId, bytes32 indexed assertionId, address asserter, bool outcome);
    event QuestionResolved(bytes32 indexed requestId, bytes32 indexed assertionId, bool outcome);
    event QuestionDisputed(bytes32 indexed requestId, bytes32 indexed assertionId);

    /// @notice Emitted when a NegRisk question is flagged as permissionless-assertable.
    event PermissionlessAssertionSet(bytes32 indexed requestId);

    /// @notice Emitted when the permissionless-assertable flag is cleared for a question.
    event PermissionlessAssertionCleared(bytes32 indexed requestId);

    event MarketChallengeAsserted(
        bytes32 indexed nrMarketId, bytes32 indexed assertionId, address indexed asserter, bytes32 reasonIpfsHash
    );

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    struct QuestionAssertion {
        bytes32 requestId;
        bytes32 assertionId;
        address asserter;
        bool outcome;
        bool settled;
    }

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    IOptimisticOracleV3 public immutable umaOracle;
    IERC20 public immutable bondToken;
    INegRiskOperatorOracle public immutable negRiskOperator;

    uint256 public immutable bondAmount;
    uint256 public immutable challengeBondAmount;
    uint64 public immutable assertionLiveness;
    bytes32 public immutable defaultIdentifier;

    /// @notice Registry wired post-deploy via `setCommunityRegistry`. Source of truth for
    ///         challenge callbacks and the only caller authorised to open challenge assertions.
    INegRiskCommunityRegistryCallback public communityRegistry;

    /// @notice assertionId => assertion data (outcome assertions)
    mapping(bytes32 => QuestionAssertion) public questionAssertions;

    /// @notice requestId => active assertionId
    mapping(bytes32 => bytes32) public requestToAssertion;

    /// @notice Addresses allowed to assert
    mapping(address => bool) public allowedAsserters;

    /// @notice Per-question flag. When true, assertOutcome bypasses the `allowedAsserters`
    ///         check so Community-tier NegRisk questions can be resolved permissionlessly.
    mapping(bytes32 => bool) internal _permissionlessAssertion;

    /// @notice assertionId => nrMarketId for Community-market challenge assertions (H.3.5).
    mapping(bytes32 => bytes32) public marketChallengeAssertions;

    /// @notice assertionId => true when the assertion is a challenge (disambiguates zero).
    mapping(bytes32 => bool) public isChallengeAssertion;

    /// @notice nrMarketId => active challenge assertionId.
    mapping(bytes32 => bytes32) public marketToChallengeAssertion;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _umaOracle,
        address _bondToken,
        address _negRiskOperator,
        uint256 _bondAmount,
        uint256 _challengeBondAmount,
        uint64 _assertionLiveness
    ) Ownable(msg.sender) {
        if (_umaOracle == address(0) || _bondToken == address(0) || _negRiskOperator == address(0)) {
            revert ZeroAddress();
        }

        umaOracle = IOptimisticOracleV3(_umaOracle);
        bondToken = IERC20(_bondToken);
        negRiskOperator = INegRiskOperatorOracle(_negRiskOperator);
        bondAmount = _bondAmount;
        challengeBondAmount = _challengeBondAmount;
        assertionLiveness = _assertionLiveness;
        defaultIdentifier = umaOracle.defaultIdentifier();

        allowedAsserters[msg.sender] = true;
    }

    /// @notice One-time wire of the NegRiskCommunityRegistry. Callable by owner; cannot be
    ///         re-set once non-zero. Required before `assertMarketChallenge` can be used.
    function setCommunityRegistry(address _registry) external onlyOwner {
        if (address(communityRegistry) != address(0)) revert AlreadyInitialized();
        if (_registry == address(0)) revert ZeroAddress();
        communityRegistry = INegRiskCommunityRegistryCallback(_registry);
    }

    // ──────────────────────────────────────────────
    // Assert
    // ──────────────────────────────────────────────

    /// @notice Assert the outcome for a NegRisk question
    /// @param requestId The oracle request ID (maps to a questionId in NegRiskOperator)
    /// @param outcome True if this outcome won, false otherwise
    /// @param asserter The address providing the bond
    function assertOutcome(bytes32 requestId, bool outcome, address asserter) external returns (bytes32) {
        if (!allowedAsserters[msg.sender] && !_permissionlessAssertion[requestId]) {
            revert UnauthorizedAsserter(msg.sender);
        }
        if (requestToAssertion[requestId] != bytes32(0)) revert QuestionAlreadyAsserted(requestId);

        bondToken.safeTransferFrom(asserter, address(this), bondAmount);
        bondToken.forceApprove(address(umaOracle), bondAmount);

        bytes memory claim = abi.encodePacked(
            "NegRisk question ", _bytes32ToHex(requestId), " outcome is ", outcome ? "YES" : "NO", " on Clov Protocol."
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

        questionAssertions[assertionId] = QuestionAssertion({
            requestId: requestId, assertionId: assertionId, asserter: asserter, outcome: outcome, settled: false
        });

        requestToAssertion[requestId] = assertionId;

        emit QuestionAsserted(requestId, assertionId, asserter, outcome);

        return assertionId;
    }

    // ──────────────────────────────────────────────
    // Assert Market Challenge (H.3.5)
    // ──────────────────────────────────────────────

    /// @notice Registry-only: open a UMA challenge assertion at the nrMarketId level.
    /// @dev Single assertion per market — *not* per-question. Claim text follows the
    ///      "NegRisk market 0x<nrMarketId> is invalid per ipfs://<reasonHash>" convention.
    function assertMarketChallenge(bytes32 nrMarketId, bytes32 reasonIpfsHash, address asserter)
        external
        returns (bytes32)
    {
        if (msg.sender != address(communityRegistry)) {
            revert OnlyRegistry(msg.sender);
        }
        if (marketToChallengeAssertion[nrMarketId] != bytes32(0)) {
            revert ChallengeAlreadyAsserted(nrMarketId);
        }

        bondToken.safeTransferFrom(asserter, address(this), challengeBondAmount);
        bondToken.forceApprove(address(umaOracle), challengeBondAmount);

        bytes memory claim = abi.encodePacked(
            "NegRisk market ", _bytes32ToHex(nrMarketId), " is invalid per ipfs://", _bytes32ToHex(reasonIpfsHash)
        );

        bytes32 assertionId = umaOracle.assertTruth(
            claim,
            asserter,
            address(this),
            address(0),
            assertionLiveness,
            bondToken,
            challengeBondAmount,
            defaultIdentifier,
            bytes32(0)
        );

        marketChallengeAssertions[assertionId] = nrMarketId;
        isChallengeAssertion[assertionId] = true;
        marketToChallengeAssertion[nrMarketId] = assertionId;

        emit MarketChallengeAsserted(nrMarketId, assertionId, asserter, reasonIpfsHash);

        return assertionId;
    }

    // ──────────────────────────────────────────────
    // UMA Callbacks
    // ──────────────────────────────────────────────

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        if (msg.sender != address(umaOracle)) revert OnlyUmaOracle();

        if (isChallengeAssertion[assertionId]) {
            bytes32 nrMarketId = marketChallengeAssertions[assertionId];
            delete marketChallengeAssertions[assertionId];
            delete isChallengeAssertion[assertionId];
            delete marketToChallengeAssertion[nrMarketId];

            if (assertedTruthfully) {
                communityRegistry.onChallengeUpheld(nrMarketId);
            } else {
                communityRegistry.onChallengeRejected(nrMarketId);
            }
            return;
        }

        QuestionAssertion storage qa = questionAssertions[assertionId];
        if (qa.assertionId == bytes32(0)) revert AssertionNotFound(assertionId);

        qa.settled = true;

        if (assertedTruthfully) {
            uint256[] memory payouts = new uint256[](2);
            if (qa.outcome) {
                payouts[0] = 1;
                payouts[1] = 0;
            } else {
                payouts[0] = 0;
                payouts[1] = 1;
            }

            negRiskOperator.reportPayouts(qa.requestId, payouts);

            emit QuestionResolved(qa.requestId, assertionId, qa.outcome);
        } else {
            requestToAssertion[qa.requestId] = bytes32(0);
            emit QuestionDisputed(qa.requestId, assertionId);
        }
    }

    function assertionDisputedCallback(bytes32 assertionId) external {
        if (msg.sender != address(umaOracle)) revert OnlyUmaOracle();

        // Challenge assertion disputed — wait for the resolved callback to route.
        if (isChallengeAssertion[assertionId]) {
            return;
        }

        QuestionAssertion storage qa = questionAssertions[assertionId];
        if (qa.assertionId == bytes32(0)) revert AssertionNotFound(assertionId);

        requestToAssertion[qa.requestId] = bytes32(0);

        emit QuestionDisputed(qa.requestId, assertionId);
    }

    // ──────────────────────────────────────────────
    // Manual Settlement
    // ──────────────────────────────────────────────

    /// @notice Trigger UMA settlement for a question
    function settleQuestion(bytes32 requestId) external {
        bytes32 assertionId = requestToAssertion[requestId];
        if (assertionId == bytes32(0)) revert AssertionNotFound(assertionId);

        QuestionAssertion storage qa = questionAssertions[assertionId];
        if (qa.settled) revert AssertionAlreadySettled(assertionId);

        umaOracle.settleAssertion(assertionId);
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function addAsserter(address asserter) external onlyOwner {
        if (asserter == address(0)) revert ZeroAddress();
        allowedAsserters[asserter] = true;
    }

    function removeAsserter(address asserter) external onlyOwner {
        if (asserter == address(0)) revert ZeroAddress();
        allowedAsserters[asserter] = false;
    }

    // ──────────────────────────────────────────────
    // Community — Permissionless Assertion (H.2.11)
    // ──────────────────────────────────────────────

    /// @notice Flag a NegRisk question as permissionless-assertable. When set, any
    ///         caller may invoke `assertOutcome` for that `requestId` without being on
    ///         the `allowedAsserters` list. Mirrors `ClovOracleAdapter` behaviour for
    ///         binary markets.
    /// @dev Only the registered NegRiskOperator may toggle this flag. Called when a
    ///      Community NegRisk question is prepared so outcome assertion is open.
    function setPermissionlessAssertion(bytes32 requestId) external {
        if (msg.sender != address(negRiskOperator)) {
            revert OnlyNegRiskOperator(msg.sender);
        }
        _permissionlessAssertion[requestId] = true;
        emit PermissionlessAssertionSet(requestId);
    }

    /// @notice Clear the permissionless-assertable flag for a NegRisk question. Called
    ///         by the NegRiskOperator on challenge or cancel so a dispute routes through
    ///         the allowlist path.
    function clearPermissionlessAssertion(bytes32 requestId) external {
        if (msg.sender != address(negRiskOperator)) {
            revert OnlyNegRiskOperator(msg.sender);
        }
        _permissionlessAssertion[requestId] = false;
        emit PermissionlessAssertionCleared(requestId);
    }

    /// @notice Returns whether a NegRisk question is currently permissionless-assertable.
    function isPermissionlessAssertion(bytes32 requestId) external view returns (bool) {
        return _permissionlessAssertion[requestId];
    }

    /// @notice NegRiskOperator calls prepareCondition on its oracle — we no-op it
    function prepareCondition(address, bytes32, uint256) external pure { }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _bytes32ToHex(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
