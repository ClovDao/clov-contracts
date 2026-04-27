// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { NegRiskCommunityRegistry } from "../src/neg-risk/NegRiskCommunityRegistry.sol";
import { NegRiskOperator } from "../src/neg-risk/NegRiskOperator.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NegRiskCommunityRegistryFuzzTest is Test {
    NegRiskCommunityRegistry public registry;
    MockERC20 public usdc;

    address public operator = makeAddr("operator");
    address public nrAdapter = makeAddr("nrAdapter");
    address public nrExchange = makeAddr("nrExchange");
    address public oracle = makeAddr("oracle");

    bytes32 public constant NR_MARKET_ID = keccak256("nrMarket-fuzz");
    bytes32 public constant QUESTION_ID = keccak256("q-fuzz");
    bytes32 public constant REASON = keccak256("reason");

    uint256 public constant FEE_BIPS = 200;

    function setUp() public {
        usdc = new MockERC20();
        registry = new NegRiskCommunityRegistry(address(usdc), operator, nrAdapter, nrExchange);
        registry.setOracle(oracle);

        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.prepareCommunityMarket.selector), abi.encode(NR_MARKET_ID)
        );
        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.prepareCommunityQuestion.selector), abi.encode(QUESTION_ID)
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.clearCommunityPermissionlessAssertion.selector),
            abi.encode()
        );
        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.setCommunityPermissionlessAssertion.selector), abi.encode()
        );
        vm.mockCall(nrAdapter, abi.encodeWithSignature("getPositionId(bytes32,bool)"), abi.encode(uint256(1)));
        vm.mockCall(nrAdapter, abi.encodeWithSignature("getConditionId(bytes32)"), abi.encode(bytes32(uint256(0xC0AD))));
        vm.mockCall(nrExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"), abi.encode());
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

    function _questions(uint256 count) internal pure returns (NegRiskCommunityRegistry.QuestionInput[] memory qs) {
        qs = new NegRiskCommunityRegistry.QuestionInput[](count);
        for (uint256 i; i < count; ++i) {
            qs[i] = NegRiskCommunityRegistry.QuestionInput({
                data: hex"deadbeef", requestId: keccak256(abi.encodePacked("req-fuzz-", i))
            });
        }
    }

    function _createMarket(address creator) internal returns (bytes32 nrMarketId) {
        uint256 deposit = registry.communityCreationDeposit();
        _fundAndApprove(creator, deposit);
        vm.prank(creator);
        nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _questions(1));
    }

    function testFuzz_createCommunityMarket_anyCaller(address creator) public {
        vm.assume(creator != address(0));
        vm.assume(creator.code.length == 0);

        bytes32 nrMarketId = _createMarket(creator);
        assertEq(registry.getMarket(nrMarketId).creator, creator);
    }

    function testFuzz_createCommunityMarket_variableQuestionCount(uint8 count) public {
        count = uint8(bound(count, 1, 20));

        address creator = makeAddr("creator");
        uint256 deposit = registry.communityCreationDeposit();
        _fundAndApprove(creator, deposit);

        vm.prank(creator);
        bytes32 nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _questions(count));

        assertEq(registry.getMarketQuestionCount(nrMarketId), count);
    }

    function testFuzz_createCommunityMarket_deadlineMatchesPeriod(uint256 warpSecs) public {
        warpSecs = bound(warpSecs, 0, 365 days);
        vm.warp(block.timestamp + warpSecs);
        uint256 t0 = block.timestamp;

        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        assertEq(registry.getMarket(nrMarketId).challengeDeadline, t0 + registry.CHALLENGE_PERIOD());
    }

    function testFuzz_createCommunityMarket_pullsDepositExact(uint256 depositSeed) public {
        uint256 deposit = bound(depositSeed, registry.MIN_CREATION_DEPOSIT(), 100_000e6);
        registry.updateCommunityCreationDeposit(deposit);

        address creator = makeAddr("creator");
        _fundAndApprove(creator, deposit);
        uint256 creatorBefore = usdc.balanceOf(creator);

        vm.prank(creator);
        bytes32 nrMarketId = registry.createCommunityMarket(FEE_BIPS, hex"deadbeef", _questions(1));

        assertEq(usdc.balanceOf(creator), creatorBefore - deposit);
        assertEq(registry.getMarket(nrMarketId).creationDeposit, deposit);
    }

    // ──────────────────────────────────────────────
    // challengeMarket fuzz
    // ──────────────────────────────────────────────

    function testFuzz_challenge_setsStateAndCallsOracle(uint256 depositSeed) public {
        uint256 deposit = bound(depositSeed, registry.MIN_CREATION_DEPOSIT(), 10_000e6);
        registry.updateCommunityCreationDeposit(deposit);

        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        registry.challengeMarket(nrMarketId, REASON);

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        assertEq(m.challenger, challenger);
        assertEq(uint8(m.creationStatus), uint8(NegRiskCommunityRegistry.CreationStatus.Challenged));
    }

    function testFuzz_challenge_revertsOutsideWindow(uint256 warpSecs) public {
        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        warpSecs = bound(warpSecs, registry.CHALLENGE_PERIOD() + 1, 365 days);
        vm.warp(block.timestamp + warpSecs);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        vm.expectRevert(NegRiskCommunityRegistry.ChallengeWindowClosed.selector);
        registry.challengeMarket(nrMarketId, REASON);
    }

    function testFuzz_challenge_withinWindowSucceeds(uint256 warpSecs) public {
        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        warpSecs = bound(warpSecs, 0, registry.CHALLENGE_PERIOD());
        vm.warp(block.timestamp + warpSecs);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        registry.challengeMarket(nrMarketId, REASON);

        assertEq(
            uint8(registry.getMarket(nrMarketId).creationStatus),
            uint8(NegRiskCommunityRegistry.CreationStatus.Challenged)
        );
    }

    function testFuzz_challenge_doubleChallengeReverts(address challenger2) public {
        vm.assume(challenger2 != address(0) && challenger2.code.length == 0);

        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        address challenger1 = makeAddr("challenger1");
        vm.prank(challenger1);
        registry.challengeMarket(nrMarketId, REASON);

        vm.prank(challenger2);
        vm.expectRevert(NegRiskCommunityRegistry.AlreadyChallenged.selector);
        registry.challengeMarket(nrMarketId, REASON);
    }

    // ──────────────────────────────────────────────
    // activateMarket fuzz
    // ──────────────────────────────────────────────

    function testFuzz_activate_revertsBeforeDeadline(uint256 warpSecs) public {
        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        warpSecs = bound(warpSecs, 0, registry.CHALLENGE_PERIOD());
        vm.warp(block.timestamp + warpSecs);

        vm.expectRevert(NegRiskCommunityRegistry.ChallengeWindowStillOpen.selector);
        registry.activateMarket(nrMarketId);
    }

    function testFuzz_activate_succeedsAfterDeadline(uint256 warpSecs) public {
        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        warpSecs = bound(warpSecs, registry.CHALLENGE_PERIOD() + 1, 30 days);
        vm.warp(block.timestamp + warpSecs);

        registry.activateMarket(nrMarketId);
        assertEq(
            uint8(registry.getMarket(nrMarketId).creationStatus), uint8(NegRiskCommunityRegistry.CreationStatus.Active)
        );
    }

    // ──────────────────────────────────────────────
    // Creator fee fuzz
    // ──────────────────────────────────────────────

    function testFuzz_accrueCreatorFee_monotonicAccumulation(uint256[5] memory amounts) public {
        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        address feePayer = makeAddr("feePayer");
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = bound(amounts[i], 1, 1_000e6);
            _fundAndApprove(feePayer, amount);
            vm.prank(feePayer);
            registry.accrueCreatorFee(nrMarketId, amount);
            total += amount;

            assertEq(registry.getMarket(nrMarketId).creatorFeeAccumulated, total);
        }
    }

    function testFuzz_claimCreatorFee_resetsAndTransfers(uint256 amount) public {
        amount = bound(amount, 1, 10_000e6);

        address creator = makeAddr("creator");
        bytes32 nrMarketId = _createMarket(creator);

        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, amount);
        vm.prank(feePayer);
        registry.accrueCreatorFee(nrMarketId, amount);

        uint256 balBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        registry.claimCreatorFee(nrMarketId);

        assertEq(registry.getMarket(nrMarketId).creatorFeeAccumulated, 0);
        assertEq(usdc.balanceOf(creator), balBefore + amount);
    }

    function testFuzz_claimCreatorFee_onlyCreator(address intruder) public {
        address creator = makeAddr("creator");
        vm.assume(intruder != creator && intruder != address(0));

        bytes32 nrMarketId = _createMarket(creator);
        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, 100e6);
        vm.prank(feePayer);
        registry.accrueCreatorFee(nrMarketId, 100e6);

        vm.prank(intruder);
        vm.expectRevert(
            abi.encodeWithSelector(NegRiskCommunityRegistry.NotMarketCreator.selector, nrMarketId, intruder)
        );
        registry.claimCreatorFee(nrMarketId);
    }

    // ──────────────────────────────────────────────
    // Refund fuzz
    // ──────────────────────────────────────────────

    function testFuzz_refundCreationDeposit_onlyCreator(address caller) public {
        address creator = makeAddr("creator");
        vm.assume(caller != creator && caller != address(0));

        bytes32 nrMarketId = _createMarket(creator);
        registry.cancelMarket(nrMarketId);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(NegRiskCommunityRegistry.NotMarketCreator.selector, nrMarketId, caller));
        registry.refundCreationDeposit(nrMarketId);
    }

    // ──────────────────────────────────────────────
    // Admin fuzz
    // ──────────────────────────────────────────────

    function testFuzz_updateCommunityCreationDeposit_revertsBelowMinimum(uint256 deposit) public {
        deposit = bound(deposit, 0, registry.MIN_CREATION_DEPOSIT() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NegRiskCommunityRegistry.DepositBelowMinimum.selector, deposit, registry.MIN_CREATION_DEPOSIT()
            )
        );
        registry.updateCommunityCreationDeposit(deposit);
    }

    function testFuzz_registryAdmin_onlyOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.updateCommunityCreationDeposit(100e6);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.pauseMarketCreation();
    }
}
