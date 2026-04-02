// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketResolver } from "../src/MarketResolver.sol";
import { IMarketResolver } from "../src/interfaces/IMarketResolver.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";

contract MarketResolverTest is Test {
    MarketResolver public resolver;

    address public owner;
    address public alice = makeAddr("alice");

    address public conditionalTokens = makeAddr("conditionalTokens");
    address public marketFactory = makeAddr("marketFactory");
    address public oracleAdapter = makeAddr("oracleAdapter");

    bytes32 public constant MOCK_QUESTION_ID = keccak256("questionId-0");
    bytes32 public constant MOCK_CONDITION_ID = keccak256("conditionId-0");
    address public constant MOCK_FPMM = address(0xF999);

    uint256 public constant MARKET_ID = 0;

    function setUp() public {
        owner = address(this);

        resolver = new MarketResolver(conditionalTokens);
        resolver.initialize(marketFactory, oracleAdapter);

        // Mock MarketFactory.getMarket — returns a Resolving market by default
        _mockGetMarket(MARKET_ID, IMarketFactory.MarketStatus.Resolving);

        // Mock ConditionalTokens.reportPayouts — just succeed
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.reportPayouts.selector),
            abi.encode()
        );

        // Mock MarketFactory.updateMarketStatus — just succeed
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector),
            abi.encode()
        );
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _mockGetMarket(uint256 marketId, IMarketFactory.MarketStatus status) internal {
        IMarketFactory.MarketData memory market = IMarketFactory.MarketData({
            questionId: MOCK_QUESTION_ID,
            conditionId: MOCK_CONDITION_ID,
            fpmm: MOCK_FPMM,
            creator: alice,
            metadataURI: "ipfs://metadata",
            creationDeposit: 10e6,
            resolutionTimestamp: block.timestamp - 1,
            status: status,
            category: IMarketFactory.Category.Sports
        });

        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.getMarket.selector, marketId),
            abi.encode(market)
        );
    }

    function _yesPayouts() internal pure returns (uint256[] memory) {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        return payouts;
    }

    function _noPayouts() internal pure returns (uint256[] memory) {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1;
        return payouts;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_setsStateCorrectly() public view {
        assertEq(address(resolver.conditionalTokens()), conditionalTokens);
        assertEq(address(resolver.marketFactory()), marketFactory);
        assertEq(resolver.oracleAdapter(), oracleAdapter);
        assertEq(resolver.owner(), owner);
    }

    function test_constructor_revertsOnZeroConditionalTokens() public {
        vm.expectRevert(MarketResolver.ZeroAddress.selector);
        new MarketResolver(address(0));
    }

    function test_initialize_revertsOnZeroMarketFactory() public {
        MarketResolver r = new MarketResolver(conditionalTokens);
        vm.expectRevert(MarketResolver.ZeroAddress.selector);
        r.initialize(address(0), oracleAdapter);
    }

    function test_initialize_revertsOnZeroOracleAdapter() public {
        MarketResolver r = new MarketResolver(conditionalTokens);
        vm.expectRevert(MarketResolver.ZeroAddress.selector);
        r.initialize(marketFactory, address(0));
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(MarketResolver.AlreadyInitialized.selector);
        resolver.initialize(marketFactory, oracleAdapter);
    }

    // ──────────────────────────────────────────────
    // resolve() — Happy Path
    // ──────────────────────────────────────────────

    function test_resolve_yesWins_setsPayouts1_0() public {
        uint256[] memory payouts = _yesPayouts();

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);

        assertTrue(resolver.isResolved(MARKET_ID));
    }

    function test_resolve_noWins_setsPayouts0_1() public {
        uint256[] memory payouts = _noPayouts();

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);

        assertTrue(resolver.isResolved(MARKET_ID));
    }

    // ──────────────────────────────────────────────
    // resolve() — Calls ConditionalTokens.reportPayouts
    // ──────────────────────────────────────────────

    function test_resolve_callsReportPayoutsWithCorrectArgs() public {
        uint256[] memory payouts = _yesPayouts();

        // Expect the exact call to reportPayouts
        vm.expectCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.reportPayouts.selector, MOCK_QUESTION_ID, payouts)
        );

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);
    }

    function test_resolve_noWins_callsReportPayoutsWithCorrectArgs() public {
        uint256[] memory payouts = _noPayouts();

        vm.expectCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.reportPayouts.selector, MOCK_QUESTION_ID, payouts)
        );

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);
    }

    // ──────────────────────────────────────────────
    // resolve() — Calls MarketFactory.updateMarketStatus
    // ──────────────────────────────────────────────

    function test_resolve_callsUpdateMarketStatusToResolved() public {
        uint256[] memory payouts = _yesPayouts();

        vm.expectCall(
            marketFactory,
            abi.encodeWithSelector(
                IMarketFactory.updateMarketStatus.selector,
                MARKET_ID,
                IMarketFactory.MarketStatus.Resolved
            )
        );

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);
    }

    // ──────────────────────────────────────────────
    // resolve() — Emits MarketResolved event
    // ──────────────────────────────────────────────

    function test_resolve_emitsMarketResolvedEvent() public {
        uint256[] memory payouts = _yesPayouts();

        vm.expectEmit(true, false, false, true);
        emit IMarketResolver.MarketResolved(MARKET_ID, payouts);

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);
    }

    function test_resolve_noWins_emitsMarketResolvedEvent() public {
        uint256[] memory payouts = _noPayouts();

        vm.expectEmit(true, false, false, true);
        emit IMarketResolver.MarketResolved(MARKET_ID, payouts);

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);
    }

    // ──────────────────────────────────────────────
    // resolve() — Access Control
    // ──────────────────────────────────────────────

    function test_resolve_revertsIfNotOracleAdapter() public {
        uint256[] memory payouts = _yesPayouts();

        vm.prank(alice);
        vm.expectRevert(MarketResolver.OnlyOracleAdapter.selector);
        resolver.resolve(MARKET_ID, payouts);
    }

    function test_resolve_revertsIfCallerIsOwner() public {
        uint256[] memory payouts = _yesPayouts();

        // Owner is not oracleAdapter — should revert
        vm.expectRevert(MarketResolver.OnlyOracleAdapter.selector);
        resolver.resolve(MARKET_ID, payouts);
    }

    // ──────────────────────────────────────────────
    // resolve() — Already Resolved
    // ──────────────────────────────────────────────

    function test_resolve_revertsIfAlreadyResolved() public {
        uint256[] memory payouts = _yesPayouts();

        // First resolve succeeds
        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);

        // Second resolve reverts
        vm.prank(oracleAdapter);
        vm.expectRevert(abi.encodeWithSelector(MarketResolver.MarketAlreadyResolved.selector, MARKET_ID));
        resolver.resolve(MARKET_ID, payouts);
    }

    // ──────────────────────────────────────────────
    // resolve() — Market doesn't exist (returns empty data)
    // ──────────────────────────────────────────────

    function test_resolve_worksWithNonexistentMarket() public {
        // MarketResolver itself doesn't check if a market exists —
        // it just calls getMarket and reportPayouts. If the underlying
        // contracts accept it, resolve proceeds. Mock returns default data.
        uint256 nonExistentId = 999;

        // Mock getMarket for nonexistent — returns zeroed-out struct
        IMarketFactory.MarketData memory emptyMarket;
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.getMarket.selector, nonExistentId),
            abi.encode(emptyMarket)
        );

        uint256[] memory payouts = _yesPayouts();

        vm.prank(oracleAdapter);
        resolver.resolve(nonExistentId, payouts);

        assertTrue(resolver.isResolved(nonExistentId));
    }

    // ──────────────────────────────────────────────
    // resolve() — Multiple markets
    // ──────────────────────────────────────────────

    function test_resolve_multipleMarketsIndependently() public {
        uint256 marketId1 = 1;
        uint256 marketId2 = 2;

        bytes32 questionId1 = keccak256("q1");
        bytes32 questionId2 = keccak256("q2");

        // Mock market 1
        IMarketFactory.MarketData memory market1 = IMarketFactory.MarketData({
            questionId: questionId1,
            conditionId: MOCK_CONDITION_ID,
            fpmm: MOCK_FPMM,
            creator: alice,
            metadataURI: "ipfs://m1",
            creationDeposit: 10e6,
            resolutionTimestamp: block.timestamp - 1,
            status: IMarketFactory.MarketStatus.Resolving,
            category: IMarketFactory.Category.Sports
        });
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.getMarket.selector, marketId1),
            abi.encode(market1)
        );

        // Mock market 2
        IMarketFactory.MarketData memory market2 = IMarketFactory.MarketData({
            questionId: questionId2,
            conditionId: MOCK_CONDITION_ID,
            fpmm: MOCK_FPMM,
            creator: alice,
            metadataURI: "ipfs://m2",
            creationDeposit: 10e6,
            resolutionTimestamp: block.timestamp - 1,
            status: IMarketFactory.MarketStatus.Resolving,
            category: IMarketFactory.Category.Gaming
        });
        vm.mockCall(
            marketFactory,
            abi.encodeWithSelector(IMarketFactory.getMarket.selector, marketId2),
            abi.encode(market2)
        );

        // Resolve market 1 with YES
        vm.prank(oracleAdapter);
        resolver.resolve(marketId1, _yesPayouts());

        // Resolve market 2 with NO
        vm.prank(oracleAdapter);
        resolver.resolve(marketId2, _noPayouts());

        assertTrue(resolver.isResolved(marketId1));
        assertTrue(resolver.isResolved(marketId2));
    }

    // ──────────────────────────────────────────────
    // isMarketResolved()
    // ──────────────────────────────────────────────

    function test_isMarketResolved_returnsFalseByDefault() public view {
        assertFalse(resolver.isMarketResolved(MARKET_ID));
        assertFalse(resolver.isMarketResolved(999));
    }

    function test_isMarketResolved_returnsTrueAfterResolve() public {
        uint256[] memory payouts = _yesPayouts();

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);

        assertTrue(resolver.isMarketResolved(MARKET_ID));
    }

    function test_isMarketResolved_otherMarketsUnaffected() public {
        uint256[] memory payouts = _yesPayouts();

        vm.prank(oracleAdapter);
        resolver.resolve(MARKET_ID, payouts);

        assertTrue(resolver.isMarketResolved(MARKET_ID));
        assertFalse(resolver.isMarketResolved(1));
        assertFalse(resolver.isMarketResolved(999));
    }
}
