// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NegRiskOperator, INegRiskOperatorEE, INegRiskOracleMutator } from "../src/neg-risk/NegRiskOperator.sol";
import { NegRiskAdapter } from "../src/neg-risk/NegRiskAdapter.sol";
import { NegRiskIdLib } from "../src/neg-risk/libraries/NegRiskIdLib.sol";
import { IAuthEE } from "../src/neg-risk/modules/interfaces/IAuth.sol";

contract NegRiskOperatorCommunityTest is Test {
    NegRiskOperator public operator;

    address public admin;
    address public nrAdapter = makeAddr("nrAdapter");
    address public oracle = makeAddr("oracle");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public constant MARKET_ID = keccak256("marketId");
    bytes32 public constant QUESTION_ID =
        bytes32(uint256(0x0102030405060708090a0b0c0d0e0f1011121314151617181920212223242526));
    bytes32 public constant REQUEST_ID = keccak256("requestId");
    uint256 public constant FEE_BIPS = 200; // 2%

    function setUp() public {
        admin = address(this);
        operator = new NegRiskOperator(nrAdapter);
        operator.setOracle(oracle);

        // nrAdapter.prepareMarket returns the market id we pre-commit to.
        vm.mockCall(nrAdapter, abi.encodeWithSelector(NegRiskAdapter.prepareMarket.selector), abi.encode(MARKET_ID));

        // nrAdapter.prepareQuestion returns a question id.
        vm.mockCall(nrAdapter, abi.encodeWithSelector(NegRiskAdapter.prepareQuestion.selector), abi.encode(QUESTION_ID));

        // Oracle permissionless setters — no-op mock so calls succeed.
        vm.mockCall(
            oracle, abi.encodeWithSelector(INegRiskOracleMutator.setPermissionlessAssertion.selector), abi.encode()
        );
        vm.mockCall(
            oracle, abi.encodeWithSelector(INegRiskOracleMutator.clearPermissionlessAssertion.selector), abi.encode()
        );
    }

    // ──────────────────────────────────────────────
    // prepareCommunityMarket — permissionless
    // ──────────────────────────────────────────────

    function test_prepareCommunityMarket_permissionless() public {
        vm.prank(alice); // not admin
        bytes32 marketId = operator.prepareCommunityMarket(FEE_BIPS, hex"1234");
        assertEq(marketId, MARKET_ID);
    }

    function test_prepareCommunityMarket_emitsCommunityEvent() public {
        bytes memory data = hex"cafebabe";

        vm.expectEmit(true, true, false, true);
        emit INegRiskOperatorEE.CommunityMarketPrepared(MARKET_ID, alice, FEE_BIPS, data);

        vm.prank(alice);
        operator.prepareCommunityMarket(FEE_BIPS, data);
    }

    function test_prepareCommunityMarket_emitsLegacyMarketPreparedEvent() public {
        bytes memory data = hex"cafebabe";

        vm.expectEmit(true, false, false, true);
        emit INegRiskOperatorEE.MarketPrepared(MARKET_ID, FEE_BIPS, data);

        vm.prank(alice);
        operator.prepareCommunityMarket(FEE_BIPS, data);
    }

    // ──────────────────────────────────────────────
    // prepareCommunityQuestion — permissionless + oracle flag
    // ──────────────────────────────────────────────

    function test_prepareCommunityQuestion_permissionless() public {
        vm.prank(alice);
        bytes32 questionId = operator.prepareCommunityQuestion(MARKET_ID, hex"abcd", REQUEST_ID);
        assertEq(questionId, QUESTION_ID);
        assertEq(operator.questionIds(REQUEST_ID), QUESTION_ID);
    }

    function test_prepareCommunityQuestion_callsOracleSetPermissionless() public {
        vm.expectCall(oracle, abi.encodeCall(INegRiskOracleMutator.setPermissionlessAssertion, (REQUEST_ID)));

        vm.prank(alice);
        operator.prepareCommunityQuestion(MARKET_ID, hex"abcd", REQUEST_ID);
    }

    function test_prepareCommunityQuestion_revertsIfOracleNotInitialized() public {
        NegRiskOperator freshOp = new NegRiskOperator(nrAdapter);
        // intentionally don't call setOracle

        vm.prank(alice);
        vm.expectRevert(INegRiskOperatorEE.OracleNotInitialized.selector);
        freshOp.prepareCommunityQuestion(MARKET_ID, hex"abcd", REQUEST_ID);
    }

    function test_prepareCommunityQuestion_revertsOnDuplicateRequestId() public {
        vm.prank(alice);
        operator.prepareCommunityQuestion(MARKET_ID, hex"abcd", REQUEST_ID);

        vm.prank(bob);
        vm.expectRevert(INegRiskOperatorEE.QuestionWithRequestIdAlreadyPrepared.selector);
        operator.prepareCommunityQuestion(MARKET_ID, hex"abcd", REQUEST_ID);
    }

    function test_prepareCommunityQuestion_emitsCommunityEvent() public {
        vm.expectEmit(true, true, true, true);
        emit INegRiskOperatorEE.CommunityQuestionPrepared(MARKET_ID, QUESTION_ID, REQUEST_ID, alice);

        vm.prank(alice);
        operator.prepareCommunityQuestion(MARKET_ID, hex"abcd", REQUEST_ID);
    }

    function test_prepareCommunityQuestion_emitsLegacyQuestionPreparedEvent() public {
        bytes memory data = hex"abcd";
        uint256 index = NegRiskIdLib.getQuestionIndex(QUESTION_ID);

        vm.expectEmit(true, true, true, true);
        emit INegRiskOperatorEE.QuestionPrepared(MARKET_ID, QUESTION_ID, REQUEST_ID, index, data);

        vm.prank(alice);
        operator.prepareCommunityQuestion(MARKET_ID, data, REQUEST_ID);
    }

    // ──────────────────────────────────────────────
    // clearCommunityPermissionlessAssertion — admin-gated
    // ──────────────────────────────────────────────

    function test_clearCommunityPermissionlessAssertion_onlyAdmin() public {
        vm.expectCall(oracle, abi.encodeCall(INegRiskOracleMutator.clearPermissionlessAssertion, (REQUEST_ID)));
        operator.clearCommunityPermissionlessAssertion(REQUEST_ID);
    }

    function test_clearCommunityPermissionlessAssertion_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        operator.clearCommunityPermissionlessAssertion(REQUEST_ID);
    }

    function test_clearCommunityPermissionlessAssertion_revertsIfOracleNotInitialized() public {
        NegRiskOperator freshOp = new NegRiskOperator(nrAdapter);

        vm.expectRevert(INegRiskOperatorEE.OracleNotInitialized.selector);
        freshOp.clearCommunityPermissionlessAssertion(REQUEST_ID);
    }
}
