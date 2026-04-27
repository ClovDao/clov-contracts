// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NegRiskCommunityRegistry } from "../src/neg-risk/NegRiskCommunityRegistry.sol";
import { NegRiskOperator } from "../src/neg-risk/NegRiskOperator.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NegRiskCommunityRegistryTest is Test {
    NegRiskCommunityRegistry public registry;
    MockERC20 public usdc;

    address public owner;
    address public operator = makeAddr("operator");
    address public nrAdapter = makeAddr("nrAdapter");
    address public nrExchange = makeAddr("nrExchange");
    address public oracle = makeAddr("oracle");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    bytes32 public constant NR_MARKET_ID = keccak256("nrMarket-1");
    bytes32 public constant QUESTION_ID_1 = keccak256("q1");
    bytes32 public constant QUESTION_ID_2 = keccak256("q2");
    bytes32 public constant REQUEST_ID_1 = keccak256("req1");
    bytes32 public constant REQUEST_ID_2 = keccak256("req2");
    bytes32 public constant REASON = keccak256("ipfs-reason");

    uint256 public constant DEFAULT_DEPOSIT = 50e6;
    uint256 public constant FEE_BIPS = 200;

    function setUp() public {
        owner = address(this);
        usdc = new MockERC20();
        registry = new NegRiskCommunityRegistry(address(usdc), operator, nrAdapter, nrExchange);
        registry.setOracle(oracle);

        // Mock the operator calls invoked by the registry.
        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.prepareCommunityMarket.selector), abi.encode(NR_MARKET_ID)
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.prepareCommunityQuestion.selector),
            abi.encode(QUESTION_ID_1)
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.clearCommunityPermissionlessAssertion.selector),
            abi.encode()
        );
        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.setCommunityPermissionlessAssertion.selector), abi.encode()
        );

        // Mock adapter + exchange surfaces called by activateMarket
        vm.mockCall(nrAdapter, abi.encodeWithSignature("getPositionId(bytes32,bool)"), abi.encode(uint256(1)));
        vm.mockCall(nrAdapter, abi.encodeWithSignature("getConditionId(bytes32)"), abi.encode(bytes32(uint256(0xC0AD))));
        vm.mockCall(nrExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"), abi.encode());

        // Mock oracle assertMarketChallenge
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("assertMarketChallenge(bytes32,bytes32,address)"),
            abi.encode(bytes32(uint256(1)))
        );
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _fundAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(registry), amount);
    }

    function _singleQuestion() internal pure returns (NegRiskCommunityRegistry.QuestionInput[] memory qs) {
        qs = new NegRiskCommunityRegistry.QuestionInput[](1);
        qs[0] = NegRiskCommunityRegistry.QuestionInput({ data: hex"abcd", requestId: REQUEST_ID_1 });
    }

    function _twoQuestions() internal pure returns (NegRiskCommunityRegistry.QuestionInput[] memory qs) {
        qs = new NegRiskCommunityRegistry.QuestionInput[](2);
        qs[0] = NegRiskCommunityRegistry.QuestionInput({ data: hex"abcd", requestId: REQUEST_ID_1 });
        qs[1] = NegRiskCommunityRegistry.QuestionInput({ data: hex"1234", requestId: REQUEST_ID_2 });
    }

    function _createMarket(address creator) internal returns (bytes32 nrMarketId) {
        _fundAndApprove(creator, DEFAULT_DEPOSIT);
        vm.prank(creator);
        nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _singleQuestion());
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_revertsOnZeroCollateral() public {
        vm.expectRevert(NegRiskCommunityRegistry.ZeroAddress.selector);
        new NegRiskCommunityRegistry(address(0), operator, nrAdapter, nrExchange);
    }

    function test_constructor_revertsOnZeroOperator() public {
        vm.expectRevert(NegRiskCommunityRegistry.ZeroAddress.selector);
        new NegRiskCommunityRegistry(address(usdc), address(0), nrAdapter, nrExchange);
    }

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(NegRiskCommunityRegistry.ZeroAddress.selector);
        new NegRiskCommunityRegistry(address(usdc), operator, address(0), nrExchange);
    }

    function test_constructor_revertsOnZeroExchange() public {
        vm.expectRevert(NegRiskCommunityRegistry.ZeroAddress.selector);
        new NegRiskCommunityRegistry(address(usdc), operator, nrAdapter, address(0));
    }

    function test_constructor_setsDefaults() public view {
        assertEq(registry.communityCreationDeposit(), 50e6);
        assertEq(registry.owner(), owner);
    }

    // ──────────────────────────────────────────────
    // createCommunityMarket
    // ──────────────────────────────────────────────

    function test_createCommunityMarket_happyPath() public {
        bytes32 nrMarketId = _createMarket(alice);
        assertEq(nrMarketId, NR_MARKET_ID);

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        assertEq(m.creator, alice);
        assertEq(m.creationDeposit, DEFAULT_DEPOSIT);
        assertEq(m.challengeDeadline, block.timestamp + registry.CHALLENGE_PERIOD());
        assertEq(uint8(m.creationStatus), uint8(NegRiskCommunityRegistry.CreationStatus.Pending));
        assertEq(m.challenger, address(0));
        assertEq(m.creatorFeeAccumulated, 0);
    }

    function test_createCommunityMarket_storesAllQuestions() public {
        _fundAndApprove(alice, DEFAULT_DEPOSIT);
        vm.prank(alice);
        bytes32 nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _twoQuestions());

        assertEq(registry.getMarketQuestionCount(nrMarketId), 2);
        NegRiskCommunityRegistry.CommunityQuestion[] memory qs = registry.getMarketQuestions(nrMarketId);
        assertEq(qs[0].requestId, REQUEST_ID_1);
        assertEq(qs[1].requestId, REQUEST_ID_2);
    }

    function test_createCommunityMarket_pullsDeposit() public {
        _fundAndApprove(alice, DEFAULT_DEPOSIT);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 registryBefore = usdc.balanceOf(address(registry));

        vm.prank(alice);
        registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _singleQuestion());

        assertEq(usdc.balanceOf(alice), aliceBefore - DEFAULT_DEPOSIT);
        assertEq(usdc.balanceOf(address(registry)), registryBefore + DEFAULT_DEPOSIT);
    }

    function test_createCommunityMarket_revertsOnEmptyQuestions() public {
        _fundAndApprove(alice, DEFAULT_DEPOSIT);
        NegRiskCommunityRegistry.QuestionInput[] memory empty = new NegRiskCommunityRegistry.QuestionInput[](0);

        vm.prank(alice);
        vm.expectRevert(NegRiskCommunityRegistry.NoQuestions.selector);
        registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", empty);
    }

    function test_createCommunityMarket_revertsWhenPaused() public {
        registry.pauseMarketCreation();
        _fundAndApprove(alice, DEFAULT_DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _singleQuestion());
    }

    function test_createCommunityMarket_revertsOnDuplicateRegistration() public {
        _createMarket(alice);

        _fundAndApprove(bob, DEFAULT_DEPOSIT);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.MarketAlreadyRegistered.selector, NR_MARKET_ID));
        registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _singleQuestion());
    }

    // ──────────────────────────────────────────────
    // challengeMarket
    // ──────────────────────────────────────────────

    function test_challengeMarket_setsStateAndCallsOracle() public {
        bytes32 nrMarketId = _createMarket(alice);

        vm.expectCall(
            oracle, abi.encodeWithSignature("assertMarketChallenge(bytes32,bytes32,address)", nrMarketId, REASON, bob)
        );
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        assertEq(uint8(m.creationStatus), uint8(NegRiskCommunityRegistry.CreationStatus.Challenged));
        assertEq(m.challenger, bob);
    }

    function test_challengeMarket_callsClearForEachQuestion() public {
        _fundAndApprove(alice, DEFAULT_DEPOSIT);
        vm.prank(alice);
        bytes32 nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _twoQuestions());

        vm.expectCall(operator, abi.encodeCall(NegRiskOperator.clearCommunityPermissionlessAssertion, (REQUEST_ID_1)));
        vm.expectCall(operator, abi.encodeCall(NegRiskOperator.clearCommunityPermissionlessAssertion, (REQUEST_ID_2)));

        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);
    }

    function test_challengeMarket_revertsOutsideWindow() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.warp(block.timestamp + registry.CHALLENGE_PERIOD() + 1);

        vm.prank(bob);
        vm.expectRevert(NegRiskCommunityRegistry.ChallengeWindowClosed.selector);
        registry.challengeMarket(nrMarketId, REASON);
    }

    function test_challengeMarket_revertsOnDoubleChallenge() public {
        bytes32 nrMarketId = _createMarket(alice);

        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        vm.prank(charlie);
        vm.expectRevert(NegRiskCommunityRegistry.AlreadyChallenged.selector);
        registry.challengeMarket(nrMarketId, REASON);
    }

    function test_challengeMarket_revertsForNonExistentMarket() public {
        bytes32 fake = keccak256("fake");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.MarketDoesNotExist.selector, fake));
        registry.challengeMarket(fake, REASON);
    }

    // ──────────────────────────────────────────────
    // activateMarket
    // ──────────────────────────────────────────────

    function test_activateMarket_afterDeadline() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.warp(block.timestamp + registry.CHALLENGE_PERIOD() + 1);

        registry.activateMarket(nrMarketId);

        assertEq(
            uint8(registry.getMarket(nrMarketId).creationStatus), uint8(NegRiskCommunityRegistry.CreationStatus.Active)
        );
    }

    function test_activateMarket_registersPerQuestionTokens() public {
        _fundAndApprove(alice, DEFAULT_DEPOSIT);
        vm.prank(alice);
        bytes32 nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _twoQuestions());

        vm.warp(block.timestamp + registry.CHALLENGE_PERIOD() + 1);

        // Activation must call registerToken twice (once per question).
        vm.expectCall(nrExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"));
        registry.activateMarket(nrMarketId);
    }

    function test_activateMarket_revertsBeforeDeadline() public {
        bytes32 nrMarketId = _createMarket(alice);

        vm.expectRevert(NegRiskCommunityRegistry.ChallengeWindowStillOpen.selector);
        registry.activateMarket(nrMarketId);
    }

    function test_activateMarket_revertsIfChallenged() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        vm.warp(block.timestamp + registry.CHALLENGE_PERIOD() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                NegRiskCommunityRegistry.InvalidMarketTransition.selector,
                NegRiskCommunityRegistry.CreationStatus.Challenged,
                NegRiskCommunityRegistry.CreationStatus.Active
            )
        );
        registry.activateMarket(nrMarketId);
    }

    // ──────────────────────────────────────────────
    // cancelMarket
    // ──────────────────────────────────────────────

    function test_cancelMarket_onlyOwner() public {
        bytes32 nrMarketId = _createMarket(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.cancelMarket(nrMarketId);
    }

    function test_cancelMarket_clearsFlagsWhenPending() public {
        _fundAndApprove(alice, DEFAULT_DEPOSIT);
        vm.prank(alice);
        bytes32 nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _twoQuestions());

        vm.expectCall(operator, abi.encodeCall(NegRiskOperator.clearCommunityPermissionlessAssertion, (REQUEST_ID_1)));
        vm.expectCall(operator, abi.encodeCall(NegRiskOperator.clearCommunityPermissionlessAssertion, (REQUEST_ID_2)));

        registry.cancelMarket(nrMarketId);
        assertEq(
            uint8(registry.getMarket(nrMarketId).creationStatus),
            uint8(NegRiskCommunityRegistry.CreationStatus.Cancelled)
        );
    }

    function test_cancelMarket_doesNotReClearWhenActive() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.warp(block.timestamp + registry.CHALLENGE_PERIOD() + 1);
        registry.activateMarket(nrMarketId);

        vm.mockCallRevert(
            operator,
            abi.encodeWithSelector(NegRiskOperator.clearCommunityPermissionlessAssertion.selector),
            "should-not-be-called"
        );

        registry.cancelMarket(nrMarketId);
        assertEq(
            uint8(registry.getMarket(nrMarketId).creationStatus),
            uint8(NegRiskCommunityRegistry.CreationStatus.Cancelled)
        );
    }

    // ──────────────────────────────────────────────
    // Oracle callbacks
    // ──────────────────────────────────────────────

    function test_onChallengeUpheld_routesDepositToChallenger() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(oracle);
        registry.onChallengeUpheld(nrMarketId);

        assertEq(usdc.balanceOf(bob), bobBefore + DEFAULT_DEPOSIT);
        assertEq(
            uint8(registry.getMarket(nrMarketId).creationStatus),
            uint8(NegRiskCommunityRegistry.CreationStatus.Cancelled)
        );
        assertEq(registry.getMarket(nrMarketId).creationDeposit, 0);
    }

    function test_onChallengeUpheld_revertsIfNotOracle() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.OnlyOracle.selector, alice));
        registry.onChallengeUpheld(nrMarketId);
    }

    function test_onChallengeRejected_restoresPendingAndExtendsDeadline() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        // Skip ahead so new deadline != old deadline
        vm.warp(block.timestamp + 10 hours);

        vm.prank(oracle);
        registry.onChallengeRejected(nrMarketId);

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        assertEq(uint8(m.creationStatus), uint8(NegRiskCommunityRegistry.CreationStatus.Pending));
        assertEq(m.challenger, address(0));
        assertEq(m.challengeDeadline, block.timestamp + registry.CHALLENGE_PERIOD());
    }

    function test_onChallengeRejected_revertsIfNotOracle() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.OnlyOracle.selector, alice));
        registry.onChallengeRejected(nrMarketId);
    }

    // ──────────────────────────────────────────────
    // isCommunityMarket filter
    // ──────────────────────────────────────────────

    function test_isCommunityMarket_falseWhilePending() public {
        bytes32 nrMarketId = _createMarket(alice);
        assertFalse(registry.isCommunityMarket(nrMarketId));
    }

    function test_isCommunityMarket_trueOnceActive() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.warp(block.timestamp + registry.CHALLENGE_PERIOD() + 1);
        registry.activateMarket(nrMarketId);
        assertTrue(registry.isCommunityMarket(nrMarketId));
    }

    function test_isCommunityMarket_falseWhenChallenged() public {
        bytes32 nrMarketId = _createMarket(alice);
        vm.prank(bob);
        registry.challengeMarket(nrMarketId, REASON);
        assertFalse(registry.isCommunityMarket(nrMarketId));
    }

    function test_isCommunityMarket_falseForUnknownId() public view {
        assertFalse(registry.isCommunityMarket(keccak256("nope")));
    }

    // ──────────────────────────────────────────────
    // Creator Fees
    // ──────────────────────────────────────────────

    function test_accrueCreatorFee_monotonicAccumulation() public {
        bytes32 nrMarketId = _createMarket(alice);
        address feePayer = makeAddr("feePayer");

        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 amount = 10e6 * (i + 1);
            _fundAndApprove(feePayer, amount);
            vm.prank(feePayer);
            registry.accrueCreatorFee(nrMarketId, amount);
            total += amount;

            assertEq(registry.getMarket(nrMarketId).creatorFeeAccumulated, total);
        }
    }

    function test_accrueCreatorFee_revertsOnNonExistentMarket() public {
        bytes32 fake = keccak256("fake");
        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, 10e6);

        vm.prank(feePayer);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.MarketDoesNotExist.selector, fake));
        registry.accrueCreatorFee(fake, 10e6);
    }

    function test_claimCreatorFee_resetsAndTransfers() public {
        bytes32 nrMarketId = _createMarket(alice);

        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, 30e6);
        vm.prank(feePayer);
        registry.accrueCreatorFee(nrMarketId, 30e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        registry.claimCreatorFee(nrMarketId);

        assertEq(registry.getMarket(nrMarketId).creatorFeeAccumulated, 0);
        assertEq(usdc.balanceOf(alice), aliceBefore + 30e6);
    }

    function test_claimCreatorFee_onlyCreator() public {
        bytes32 nrMarketId = _createMarket(alice);

        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, 10e6);
        vm.prank(feePayer);
        registry.accrueCreatorFee(nrMarketId, 10e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.NotMarketCreator.selector, nrMarketId, bob));
        registry.claimCreatorFee(nrMarketId);
    }

    function test_claimCreatorFee_revertsWhenEmpty() public {
        bytes32 nrMarketId = _createMarket(alice);

        vm.prank(alice);
        vm.expectRevert(NegRiskCommunityRegistry.NoCreatorFeeToClaim.selector);
        registry.claimCreatorFee(nrMarketId);
    }

    // ──────────────────────────────────────────────
    // Refund
    // ──────────────────────────────────────────────

    function test_refundCreationDeposit_happyPath() public {
        bytes32 nrMarketId = _createMarket(alice);
        registry.cancelMarket(nrMarketId);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        registry.refundCreationDeposit(nrMarketId);

        assertEq(usdc.balanceOf(alice), aliceBefore + DEFAULT_DEPOSIT);
        assertEq(registry.getMarket(nrMarketId).creationDeposit, 0);
    }

    function test_refundCreationDeposit_revertsIfNotCancelled() public {
        bytes32 nrMarketId = _createMarket(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.NotRefundable.selector, nrMarketId));
        registry.refundCreationDeposit(nrMarketId);
    }

    function test_refundCreationDeposit_onlyCreator() public {
        bytes32 nrMarketId = _createMarket(alice);
        registry.cancelMarket(nrMarketId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.NotMarketCreator.selector, nrMarketId, bob));
        registry.refundCreationDeposit(nrMarketId);
    }

    function test_refundCreationDeposit_revertsOnDoubleRefund() public {
        bytes32 nrMarketId = _createMarket(alice);
        registry.cancelMarket(nrMarketId);

        vm.prank(alice);
        registry.refundCreationDeposit(nrMarketId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.DepositAlreadyRefunded.selector, nrMarketId));
        registry.refundCreationDeposit(nrMarketId);
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function test_updateCommunityCreationDeposit_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.updateCommunityCreationDeposit(100e6);
    }

    function test_updateCommunityCreationDeposit_revertsBelowMinimum() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NegRiskCommunityRegistry.DepositBelowMinimum.selector, 0, registry.MIN_CREATION_DEPOSIT()
            )
        );
        registry.updateCommunityCreationDeposit(0);
    }

    function test_pauseAndUnpause_onlyOwner() public {
        registry.pauseMarketCreation();
        assertTrue(registry.paused());
        registry.unpauseMarketCreation();
        assertFalse(registry.paused());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.pauseMarketCreation();
    }
}
