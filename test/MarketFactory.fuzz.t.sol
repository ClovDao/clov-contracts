// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";
import { IClovOracleAdapter } from "../src/interfaces/IClovOracleAdapter.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MarketFactoryHarness is MarketFactory {
    constructor(address _collateralToken, address _conditionalTokens, address _ctfExchange, uint256 _creationDeposit)
        MarketFactory(_collateralToken, _conditionalTokens, _ctfExchange, _creationDeposit)
    { }

    function setMarketStatus(uint256 marketId, MarketStatus status) external {
        markets[marketId].status = status;
    }
}

contract MarketFactoryFuzzTest is Test {
    MarketFactoryHarness public factory;
    MockERC20 public usdc;

    address public conditionalTokens = makeAddr("conditionalTokens");
    address public ctfExchange = makeAddr("ctfExchange");
    address public oracleAdapter = makeAddr("oracleAdapter");
    address public marketResolver = makeAddr("marketResolver");

    uint256 public constant CREATION_DEPOSIT = 10e6;

    bytes32 public constant MOCK_CONDITION_ID = keccak256("mockConditionId");

    function setUp() public {
        usdc = new MockERC20();
        factory = new MarketFactoryHarness(address(usdc), conditionalTokens, ctfExchange, CREATION_DEPOSIT);
        factory.initialize(oracleAdapter, marketResolver);

        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode()
        );
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getConditionId.selector),
            abi.encode(MOCK_CONDITION_ID)
        );
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getCollectionId.selector),
            abi.encode(bytes32(uint256(0xC0)))
        );
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.getPositionId.selector), abi.encode(uint256(1))
        );

        // Mock exchange registerToken — factory calls it at create/activate
        vm.mockCall(ctfExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"), abi.encode());

        // mock permissionless-assertion setters on the oracle adapter EOA so
        // createCommunityMarket / challengeMarket / cancelMarket can call through.
        vm.mockCall(
            oracleAdapter, abi.encodeWithSelector(IClovOracleAdapter.setPermissionlessAssertion.selector), abi.encode()
        );
        vm.mockCall(
            oracleAdapter,
            abi.encodeWithSelector(IClovOracleAdapter.clearPermissionlessAssertion.selector),
            abi.encode()
        );
        vm.mockCall(
            oracleAdapter,
            abi.encodeWithSelector(IClovOracleAdapter.assertMarketChallenge.selector),
            abi.encode(bytes32(uint256(1)))
        );
    }

    // ──────────────────────────────────────────────
    // createMarket fuzz
    // ──────────────────────────────────────────────

    function testFuzz_createMarket_alwaysIncrementsCount(uint256 hoursAhead) public {
        hoursAhead = bound(hoursAhead, 2, 365 * 24); // 2 hours to 1 year

        address creator = makeAddr("fuzzCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 countBefore = factory.marketCount();
        factory.createMarket("ipfs://fuzz", block.timestamp + hoursAhead * 1 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        assertEq(factory.marketCount(), countBefore + 1);
    }

    function testFuzz_createMarket_creatorIsAlwaysMsgSender(address creator) public {
        vm.assume(creator != address(0));
        vm.assume(creator.code.length == 0); // EOA only (no contracts that might reject transfers)

        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        assertEq(factory.getMarket(marketId).creator, creator);
    }

    function testFuzz_createMarket_storesCorrectDeposit(uint256 deposit) public {
        deposit = bound(deposit, factory.MIN_CREATION_DEPOSIT(), 100_000e6);

        // Update creation deposit to fuzzed value
        factory.updateCreationDeposit(deposit);

        address creator = makeAddr("fuzzCreator");
        usdc.mint(creator, deposit);

        vm.startPrank(creator);
        usdc.approve(address(factory), deposit);

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        assertEq(factory.getMarket(marketId).creationDeposit, deposit);
    }

    function testFuzz_createMarket_revertsInvalidTimestamp(uint256 timestamp) public {
        // Any timestamp <= block.timestamp + 1 hour should revert
        timestamp = bound(timestamp, 0, block.timestamp + 1 hours);

        address creator = makeAddr("fuzzCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createMarket("ipfs://fuzz", timestamp, IMarketFactory.Category.Futbol);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // updateCreationDeposit fuzz
    // ──────────────────────────────────────────────

    function testFuzz_updateCreationDeposit_acceptsValidValues(uint256 deposit) public {
        deposit = bound(deposit, factory.MIN_CREATION_DEPOSIT(), type(uint256).max);
        factory.updateCreationDeposit(deposit);
        assertEq(factory.creationDeposit(), deposit);
    }

    function testFuzz_updateCreationDeposit_revertsBelowMinimum(uint256 deposit) public {
        deposit = bound(deposit, 0, factory.MIN_CREATION_DEPOSIT() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(MarketFactory.DepositBelowMinimum.selector, deposit, factory.MIN_CREATION_DEPOSIT())
        );
        factory.updateCreationDeposit(deposit);
    }

    function testFuzz_updateCreationDeposit_onlyOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        factory.updateCreationDeposit(20e6);
    }

    // ──────────────────────────────────────────────
    // refundCreationDeposit fuzz
    // ──────────────────────────────────────────────

    function testFuzz_refundCreationDeposit_refundsExactAmount(uint256 deposit) public {
        deposit = bound(deposit, factory.MIN_CREATION_DEPOSIT(), 100_000e6);
        factory.updateCreationDeposit(deposit);

        address creator = makeAddr("fuzzCreator");
        usdc.mint(creator, deposit);

        vm.startPrank(creator);
        usdc.approve(address(factory), deposit);

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        uint256 balanceBefore = usdc.balanceOf(creator);

        vm.prank(creator);
        factory.refundCreationDeposit(marketId);

        assertEq(usdc.balanceOf(creator), balanceBefore + deposit);
        assertEq(factory.getMarket(marketId).creationDeposit, 0);
    }

    function testFuzz_refundCreationDeposit_revertsForNonCreator(address caller) public {
        address creator = makeAddr("realCreator");
        vm.assume(caller != creator);

        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.NotMarketCreator.selector, marketId, caller));
        factory.refundCreationDeposit(marketId);
    }

    function testFuzz_refundCreationDeposit_revertsForNonTerminalStatus(uint8 statusRaw) public {
        // Only statuses 0-4 are valid, exclude terminal states: Resolved (3) and Cancelled (4)
        statusRaw = uint8(bound(statusRaw, 0, 4));
        vm.assume(statusRaw != uint8(IMarketFactory.MarketStatus.Resolved));
        vm.assume(statusRaw != uint8(IMarketFactory.MarketStatus.Cancelled));

        address creator = makeAddr("fuzzCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus(statusRaw));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketNotResolvedOrCancelled.selector, marketId));
        factory.refundCreationDeposit(marketId);
    }

    // ──────────────────────────────────────────────
    // State Transition Validation fuzz (SH-T01)
    // ──────────────────────────────────────────────

    /// @dev Returns true if (from, to) is a valid state transition
    function _isValidTransition(IMarketFactory.MarketStatus from, IMarketFactory.MarketStatus to)
        internal
        pure
        returns (bool)
    {
        // Created → Active
        if (from == IMarketFactory.MarketStatus.Created && to == IMarketFactory.MarketStatus.Active) return true;
        // Created → Cancelled (Community-tier cancel before activation)
        if (from == IMarketFactory.MarketStatus.Created && to == IMarketFactory.MarketStatus.Cancelled) return true;
        // Active → Resolving
        if (from == IMarketFactory.MarketStatus.Active && to == IMarketFactory.MarketStatus.Resolving) return true;
        // Active → Cancelled
        if (from == IMarketFactory.MarketStatus.Active && to == IMarketFactory.MarketStatus.Cancelled) return true;
        // Resolving → Active
        if (from == IMarketFactory.MarketStatus.Resolving && to == IMarketFactory.MarketStatus.Active) return true;
        // Resolving → Cancelled (emergency cancel during dispute)
        if (from == IMarketFactory.MarketStatus.Resolving && to == IMarketFactory.MarketStatus.Cancelled) return true;
        // Resolving → Resolved
        if (from == IMarketFactory.MarketStatus.Resolving && to == IMarketFactory.MarketStatus.Resolved) return true;
        return false;
    }

    /// @notice Fuzz all 5×5 state transition combinations — only valid ones succeed
    function testFuzz_stateTransition_allCombinations(uint8 fromRaw, uint8 toRaw) public {
        fromRaw = uint8(bound(fromRaw, 0, 4));
        toRaw = uint8(bound(toRaw, 0, 4));

        IMarketFactory.MarketStatus from = IMarketFactory.MarketStatus(fromRaw);
        IMarketFactory.MarketStatus to = IMarketFactory.MarketStatus(toRaw);

        // Create a market and force it into the `from` state via harness
        address creator = makeAddr("fuzzCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        // Force market into the `from` status
        factory.setMarketStatus(marketId, from);

        // Attempt transition as oracleAdapter
        if (_isValidTransition(from, to)) {
            vm.prank(oracleAdapter);
            factory.updateMarketStatus(marketId, to);
            assertEq(uint8(factory.getMarket(marketId).status), uint8(to));
        } else {
            vm.prank(oracleAdapter);
            vm.expectRevert(abi.encodeWithSelector(MarketFactory.InvalidStateTransition.selector, from, to));
            factory.updateMarketStatus(marketId, to);
        }
    }

    /// @notice Explicitly test all valid transitions succeed
    function test_stateTransition_validTransitions() public {
        _testValidTransition(IMarketFactory.MarketStatus.Created, IMarketFactory.MarketStatus.Active);
        _testValidTransition(IMarketFactory.MarketStatus.Active, IMarketFactory.MarketStatus.Resolving);
        _testValidTransition(IMarketFactory.MarketStatus.Active, IMarketFactory.MarketStatus.Cancelled);
        _testValidTransition(IMarketFactory.MarketStatus.Resolving, IMarketFactory.MarketStatus.Active);
        _testValidTransition(IMarketFactory.MarketStatus.Resolving, IMarketFactory.MarketStatus.Cancelled);
        _testValidTransition(IMarketFactory.MarketStatus.Resolving, IMarketFactory.MarketStatus.Resolved);
    }

    function _testValidTransition(IMarketFactory.MarketStatus from, IMarketFactory.MarketStatus to) internal {
        address creator = makeAddr("transitionCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://transition", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        factory.setMarketStatus(marketId, from);

        vm.prank(oracleAdapter);
        factory.updateMarketStatus(marketId, to);

        assertEq(uint8(factory.getMarket(marketId).status), uint8(to));
    }

    /// @notice Resolved is a terminal state — no transitions out
    function testFuzz_stateTransition_resolvedIsTerminal(uint8 toRaw) public {
        toRaw = uint8(bound(toRaw, 0, 4));
        IMarketFactory.MarketStatus to = IMarketFactory.MarketStatus(toRaw);

        address creator = makeAddr("terminalCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://terminal", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        vm.prank(oracleAdapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketFactory.InvalidStateTransition.selector, IMarketFactory.MarketStatus.Resolved, to
            )
        );
        factory.updateMarketStatus(marketId, to);
    }

    // ──────────────────────────────────────────────
    // Community Markets fuzz
    // ──────────────────────────────────────────────

    function _fundAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(factory), amount);
    }

    function _createCommunity(address creator, uint256 hoursAhead) internal returns (uint256 marketId) {
        uint256 deposit = factory.communityCreationDeposit();
        _fundAndApprove(creator, deposit);
        vm.prank(creator);
        marketId = factory.createCommunityMarket(
            "ipfs://community-fuzz", block.timestamp + hoursAhead * 1 hours, IMarketFactory.Category.Futbol
        );
    }

    function testFuzz_createCommunity_storesPendingAndDeadline(uint256 hoursAhead) public {
        hoursAhead = bound(hoursAhead, 72, 365 * 24); // resolution > 48h + buffer
        address creator = makeAddr("commCreator");

        uint256 t0 = block.timestamp;
        uint256 marketId = _createCommunity(creator, hoursAhead);

        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);

        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Created));
        assertEq(uint8(ext.tier), uint8(IMarketFactory.MarketTier.Community));
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Pending));
        assertEq(ext.challengeDeadline, t0 + factory.CHALLENGE_PERIOD());
        assertEq(ext.challenger, address(0));
        assertEq(ext.creatorFeeAccumulated, 0);
        assertEq(m.creationDeposit, factory.communityCreationDeposit());
        assertEq(m.creator, creator);
    }

    function testFuzz_createCommunity_anyCaller(address creator) public {
        vm.assume(creator != address(0));
        vm.assume(creator.code.length == 0);

        uint256 marketId = _createCommunity(creator, 72);
        assertEq(factory.getMarket(marketId).creator, creator);
    }

    bytes32 constant REASON = keccak256("reason");

    function testFuzz_challenge_setsStateAndCallsAdapter(uint256 depositSeed) public {
        uint256 deposit = bound(depositSeed, factory.MIN_CREATION_DEPOSIT(), 10_000e6);
        factory.updateCommunityCreationDeposit(deposit);

        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 72);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        factory.challengeMarket(marketId, REASON);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(ext.challenger, challenger);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Challenged));
    }

    function testFuzz_challenge_revertsOutsideWindow(uint256 warpSecs) public {
        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 72);

        warpSecs = bound(warpSecs, factory.CHALLENGE_PERIOD() + 1, 365 days);
        vm.warp(block.timestamp + warpSecs);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        vm.expectRevert(IMarketFactory.ChallengeWindowClosed.selector);
        factory.challengeMarket(marketId, REASON);
    }

    function testFuzz_challenge_withinWindowSucceeds(uint256 warpSecs) public {
        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 72);

        warpSecs = bound(warpSecs, 0, factory.CHALLENGE_PERIOD());
        vm.warp(block.timestamp + warpSecs);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        factory.challengeMarket(marketId, REASON);

        assertEq(
            uint8(factory.getMarketExtended(marketId).creationStatus),
            uint8(IMarketFactory.MarketCreationStatus.Challenged)
        );
    }

    function testFuzz_challenge_doubleChallengeReverts(address challenger2) public {
        vm.assume(challenger2 != address(0) && challenger2.code.length == 0);

        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 72);

        address challenger1 = makeAddr("challenger1");
        vm.prank(challenger1);
        factory.challengeMarket(marketId, REASON);

        vm.prank(challenger2);
        vm.expectRevert(IMarketFactory.AlreadyChallenged.selector);
        factory.challengeMarket(marketId, REASON);
    }

    function testFuzz_activate_revertsBeforeDeadline(uint256 warpSecs) public {
        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 72);

        warpSecs = bound(warpSecs, 0, factory.CHALLENGE_PERIOD());
        vm.warp(block.timestamp + warpSecs);

        vm.expectRevert(IMarketFactory.ChallengeWindowStillOpen.selector);
        factory.activateMarket(marketId);
    }

    function testFuzz_activate_succeedsAfterDeadline(uint256 warpSecs) public {
        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 24 * 30); // 30 days ahead

        warpSecs = bound(warpSecs, factory.CHALLENGE_PERIOD() + 1, 20 days);
        vm.warp(block.timestamp + warpSecs);

        factory.activateMarket(marketId);

        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Active));
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Active));
    }

    function testFuzz_activate_revertsIfChallenged() public {
        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 24 * 30);

        address challenger = makeAddr("challenger");
        vm.prank(challenger);
        factory.challengeMarket(marketId, REASON);

        vm.warp(block.timestamp + factory.CHALLENGE_PERIOD() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Challenged,
                IMarketFactory.MarketCreationStatus.Active
            )
        );
        factory.activateMarket(marketId);
    }

    function testFuzz_accrueCreatorFee_monotonicAccumulation(uint256[5] memory amounts) public {
        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 24 * 30);

        address feePayer = makeAddr("feePayer");
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1, 1_000e6);
            _fundAndApprove(feePayer, amount);
            vm.prank(feePayer);
            factory.accrueCreatorFee(marketId, amount);
            total += amount;

            assertEq(factory.getMarketExtended(marketId).creatorFeeAccumulated, total);
        }
    }

    function testFuzz_claimCreatorFee_resetsAndTransfers(uint256 amount) public {
        amount = bound(amount, 1, 10_000e6);

        address creator = makeAddr("commCreator");
        uint256 marketId = _createCommunity(creator, 24 * 30);

        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, amount);
        vm.prank(feePayer);
        factory.accrueCreatorFee(marketId, amount);

        uint256 balBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        factory.claimCreatorFee(marketId);

        assertEq(factory.getMarketExtended(marketId).creatorFeeAccumulated, 0);
        assertEq(usdc.balanceOf(creator), balBefore + amount);
    }

    function testFuzz_claimCreatorFee_onlyCreator(address intruder) public {
        address creator = makeAddr("commCreator");
        vm.assume(intruder != creator && intruder != address(0));

        uint256 marketId = _createCommunity(creator, 24 * 30);
        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, 100e6);
        vm.prank(feePayer);
        factory.accrueCreatorFee(marketId, 100e6);

        vm.prank(intruder);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.NotMarketCreator.selector, marketId, intruder));
        factory.claimCreatorFee(marketId);
    }

    function testFuzz_accrueCreatorFee_revertsOnFeaturedMarket() public {
        address creator = makeAddr("featuredCreator");
        _fundAndApprove(creator, CREATION_DEPOSIT);
        vm.prank(creator);
        uint256 marketId =
            factory.createMarket("ipfs://featured", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);

        address feePayer = makeAddr("feePayer");
        _fundAndApprove(feePayer, 100e6);
        vm.prank(feePayer);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, marketId));
        factory.accrueCreatorFee(marketId, 100e6);
    }

    function testFuzz_updateCommunityCreationDeposit_revertsBelowMinimum(uint256 deposit) public {
        deposit = bound(deposit, 0, factory.MIN_CREATION_DEPOSIT() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(MarketFactory.DepositBelowMinimum.selector, deposit, factory.MIN_CREATION_DEPOSIT())
        );
        factory.updateCommunityCreationDeposit(deposit);
    }

    function testFuzz_communityAdmin_onlyOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        factory.updateCommunityCreationDeposit(100e6);
    }

    /// @notice Cancelled is a terminal state — no transitions out
    function testFuzz_stateTransition_cancelledIsTerminal(uint8 toRaw) public {
        toRaw = uint8(bound(toRaw, 0, 4));
        IMarketFactory.MarketStatus to = IMarketFactory.MarketStatus(toRaw);

        address creator = makeAddr("terminalCreator");
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://terminal", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Cancelled);

        vm.prank(oracleAdapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketFactory.InvalidStateTransition.selector, IMarketFactory.MarketStatus.Cancelled, to
            )
        );
        factory.updateMarketStatus(marketId, to);
    }
}
