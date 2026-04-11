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

/// @title ClovNegRiskOracle
/// @notice Bridges UMA OOV3 with NegRiskOperator for categorical market resolution
/// @dev Each NegRisk question gets its own UMA assertion. On resolution, calls reportPayouts on the operator.
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

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event QuestionAsserted(bytes32 indexed requestId, bytes32 indexed assertionId, address asserter, bool outcome);
    event QuestionResolved(bytes32 indexed requestId, bytes32 indexed assertionId, bool outcome);
    event QuestionDisputed(bytes32 indexed requestId, bytes32 indexed assertionId);

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
    uint64 public immutable assertionLiveness;
    bytes32 public immutable defaultIdentifier;

    /// @notice assertionId => assertion data
    mapping(bytes32 => QuestionAssertion) public questionAssertions;

    /// @notice requestId => active assertionId
    mapping(bytes32 => bytes32) public requestToAssertion;

    /// @notice Addresses allowed to assert
    mapping(address => bool) public allowedAsserters;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _umaOracle,
        address _bondToken,
        address _negRiskOperator,
        uint256 _bondAmount,
        uint64 _assertionLiveness
    ) Ownable(msg.sender) {
        if (_umaOracle == address(0) || _bondToken == address(0) || _negRiskOperator == address(0)) {
            revert ZeroAddress();
        }

        umaOracle = IOptimisticOracleV3(_umaOracle);
        bondToken = IERC20(_bondToken);
        negRiskOperator = INegRiskOperatorOracle(_negRiskOperator);
        bondAmount = _bondAmount;
        assertionLiveness = _assertionLiveness;
        defaultIdentifier = umaOracle.defaultIdentifier();

        allowedAsserters[msg.sender] = true;
    }

    // ──────────────────────────────────────────────
    // Assert
    // ──────────────────────────────────────────────

    /// @notice Assert the outcome for a NegRisk question
    /// @param requestId The oracle request ID (maps to a questionId in NegRiskOperator)
    /// @param outcome True if this outcome won, false otherwise
    /// @param asserter The address providing the bond
    function assertOutcome(bytes32 requestId, bool outcome, address asserter) external returns (bytes32) {
        if (!allowedAsserters[msg.sender]) revert UnauthorizedAsserter(msg.sender);
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
    // UMA Callbacks
    // ──────────────────────────────────────────────

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        if (msg.sender != address(umaOracle)) revert OnlyUmaOracle();

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
