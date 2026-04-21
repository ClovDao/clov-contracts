// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { ClovOracleAdapter } from "../src/ClovOracleAdapter.sol";
import { MarketResolver } from "../src/MarketResolver.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IClovOracleAdapter } from "../src/interfaces/IClovOracleAdapter.sol";
import { IMarketResolver } from "../src/interfaces/IMarketResolver.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";
import { IOptimisticOracleV3 } from "../src/interfaces/IOptimisticOracleV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC with public mint
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title IntegrationTest — Core lifecycle of a Clov prediction market
/// @notice Tests the core flow: create market → assert → UMA callback → resolve
/// @dev Uses REAL Clov contracts (MarketFactory, ClovOracleAdapter, MarketResolver) with mocked
///      external dependencies (Gnosis ConditionalTokens, UMA Oracle) since Gnosis contracts
///      are Solidity 0.5.x and cannot be co-compiled with 0.8.24.
///
///      NOTE: Trading logic (FPMM) has been removed in Clov 2.0 (CLOB pivot). Trading is now
///      handled externally by the CTF Exchange CLOB and is not tested in this integration test.
contract IntegrationTest is Test {
    // ──────────────────────────────────────────────
    // Contracts
    // ──────────────────────────────────────────────

    MarketFactory public factory;
    ClovOracleAdapter public oracleAdapter;
    MarketResolver public resolver;
    MockUSDC public usdc;

    // ──────────────────────────────────────────────
    // Mocked external addresses
    // ──────────────────────────────────────────────

    address public conditionalTokens = makeAddr("conditionalTokens");
    address public ctfExchange = makeAddr("ctfExchange");
    address public umaOracle = makeAddr("umaOracle");

    // ──────────────────────────────────────────────
    // Actors
    // ──────────────────────────────────────────────

    address public deployer;
    address public creator = makeAddr("creator");
    address public user1 = makeAddr("user1");
    address public asserter = makeAddr("asserter");

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 public constant CREATION_DEPOSIT = 10e6; // 10 USDC
    uint256 public constant BOND_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant CHALLENGE_BOND_AMOUNT = 500e6; // 500 USDC
    uint64 public constant ASSERTION_LIVENESS = 7200; // 2 hours
    bytes32 public constant DEFAULT_IDENTIFIER = keccak256("ASSERT_TRUTH");
    bytes32 public constant MOCK_CONDITION_ID = keccak256("integration-condition-0");
    bytes32 public constant MOCK_ASSERTION_ID = keccak256("integration-assertion-0");

    // ──────────────────────────────────────────────
    // Setup
    // ──────────────────────────────────────────────

    function setUp() public {
        deployer = address(this);
        usdc = new MockUSDC();

        // ── Mock ConditionalTokens ──
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode()
        );
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getConditionId.selector),
            abi.encode(MOCK_CONDITION_ID)
        );
        vm.mockCall(conditionalTokens, abi.encodeWithSelector(IConditionalTokens.reportPayouts.selector), abi.encode());

        // ── Mock UMA Oracle ──
        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector),
            abi.encode(DEFAULT_IDENTIFIER)
        );
        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(MOCK_ASSERTION_ID)
        );

        // ── Mock CTFExchange.registerToken + CT position helpers ──
        vm.mockCall(ctfExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"), abi.encode());
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getCollectionId.selector),
            abi.encode(bytes32(uint256(0xC0)))
        );
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.getPositionId.selector), abi.encode(uint256(1))
        );

        // ── Deploy real Clov contracts (staged with initialize) ──
        factory = new MarketFactory(address(usdc), conditionalTokens, ctfExchange, CREATION_DEPOSIT);

        oracleAdapter =
            new ClovOracleAdapter(umaOracle, address(usdc), BOND_AMOUNT, CHALLENGE_BOND_AMOUNT, ASSERTION_LIVENESS);

        resolver = new MarketResolver(conditionalTokens);

        // Wire cross-references
        factory.initialize(address(oracleAdapter), address(resolver));
        oracleAdapter.initialize(address(factory), address(resolver));
        resolver.initialize(address(factory), address(oracleAdapter));
    }

    // ──────────────────────────────────────────────
    // Full Lifecycle Test (create → assert → resolve)
    // ──────────────────────────────────────────────

    function test_fullLifecycle_createAssertResolve() public {
        // PHASE 1: Create Market
        uint256 marketId = _createMarketAsCreator(
            "ipfs://will-team-a-win", block.timestamp + 2 hours, IMarketFactory.Category.Futbol
        );

        assertEq(marketId, 0, "first market should be id 0");
        assertEq(factory.marketCount(), 1, "market count should be 1");

        {
            IMarketFactory.MarketData memory market = factory.getMarket(marketId);
            assertEq(uint8(market.status), uint8(IMarketFactory.MarketStatus.Active), "market should be Active");
            assertEq(market.creator, creator, "creator mismatch");
            assertEq(market.conditionId, MOCK_CONDITION_ID, "conditionId mismatch");
            assertTrue(market.questionId != bytes32(0), "questionId should not be zero");
        }

        // Factory should hold the creation deposit
        assertEq(usdc.balanceOf(address(factory)), CREATION_DEPOSIT, "factory should hold deposit");
        // Creator should have 0 left
        assertEq(usdc.balanceOf(creator), 0, "creator should have spent deposit");

        // PHASE 2: Assert outcome (YES wins)
        {
            uint256 resTs = factory.getMarket(marketId).resolutionTimestamp;
            vm.warp(resTs + 1);
        }

        usdc.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);

        bytes32 assertionId = oracleAdapter.assertOutcome(marketId, true, asserter);
        assertEq(assertionId, MOCK_ASSERTION_ID, "assertionId should match mock");

        // Market should now be Resolving
        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolving),
            "market should be Resolving"
        );

        // Verify assertion data stored correctly
        _verifyAssertionData(assertionId, marketId);

        // PHASE 3: UMA confirms truth → resolve
        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertionId, true);

        // PHASE 4: Verify market is Resolved
        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolved),
            "market should be Resolved"
        );
        assertTrue(resolver.isMarketResolved(marketId), "resolver should mark market as resolved");

        {
            IClovOracleAdapter.Assertion memory assertion = oracleAdapter.getAssertion(assertionId);
            assertTrue(assertion.settled, "assertion should be settled");
            assertTrue(assertion.resolved, "assertion should be resolved");
        }

        // PHASE 5: Creator reclaims deposit
        _refundAndVerifyDeposit(marketId);
    }

    // ──────────────────────────────────────────────
    // Lifecycle with dispute (assertion denied)
    // ──────────────────────────────────────────────

    function test_lifecycle_assertionDenied_marketResetsToActive() public {
        // Create market
        uint256 marketId = _createMarketAsCreator(
            "ipfs://disputed-market", block.timestamp + 2 hours, IMarketFactory.Category.Esports
        );

        IMarketFactory.MarketData memory market = factory.getMarket(marketId);

        // Warp past resolution
        vm.warp(market.resolutionTimestamp + 1);

        // First assertion: YES
        usdc.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);

        bytes32 assertionId = oracleAdapter.assertOutcome(marketId, true, asserter);

        // Market is Resolving
        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolving),
            "should be Resolving"
        );

        // UMA denies the assertion (assertedTruthfully = false)
        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertionId, false);

        // Market should be back to Active
        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Active),
            "should be Active after denied assertion"
        );

        // A new assertion can now be made
        bytes32 secondAssertionId = keccak256("second-assertion");
        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(secondAssertionId)
        );

        usdc.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);

        bytes32 newAssertionId = oracleAdapter.assertOutcome(marketId, false, asserter);
        assertEq(newAssertionId, secondAssertionId, "second assertion should use new ID");

        // UMA confirms this time
        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(secondAssertionId, true);

        // Market should be Resolved with NO winning
        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolved),
            "should be Resolved after confirmed assertion"
        );
        assertTrue(resolver.isMarketResolved(marketId), "resolver should mark resolved");
    }

    // ──────────────────────────────────────────────
    // Access control integration
    // ──────────────────────────────────────────────

    function test_lifecycle_onlyAdapterCanResolve() public {
        // Random address cannot call resolver.resolve
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(user1);
        vm.expectRevert(MarketResolver.OnlyOracleAdapter.selector);
        resolver.resolve(0, payouts);
    }

    function test_lifecycle_onlyUmaCanCallbackAdapter() public {
        // Random address cannot call assertionResolvedCallback
        vm.prank(user1);
        vm.expectRevert(ClovOracleAdapter.OnlyUmaOracle.selector);
        oracleAdapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);
    }

    function test_lifecycle_onlyAdapterOrResolverCanUpdateStatus() public {
        // Random address cannot update market status
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.UnauthorizedStatusUpdate.selector, user1));
        factory.updateMarketStatus(0, IMarketFactory.MarketStatus.Resolved);
    }

    // ──────────────────────────────────────────────
    // Multiple markets lifecycle
    // ──────────────────────────────────────────────

    function test_lifecycle_multipleMarketsIndependent() public {
        // Create two markets
        usdc.mint(creator, CREATION_DEPOSIT * 2);
        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT * 2);

        uint256 market0 =
            factory.createMarket("ipfs://market-0", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        uint256 market1 =
            factory.createMarket("ipfs://market-1", block.timestamp + 3 hours, IMarketFactory.Category.Esports);
        vm.stopPrank();

        assertEq(market0, 0);
        assertEq(market1, 1);
        assertEq(factory.marketCount(), 2);

        // Warp past both resolution timestamps
        vm.warp(block.timestamp + 4 hours);

        // Resolve market 0 as YES
        _assertAndResolveMarket(market0, true, keccak256("assert-market-0"));

        // Market 0 is Resolved, Market 1 still Active
        assertEq(uint8(factory.getMarket(market0).status), uint8(IMarketFactory.MarketStatus.Resolved));
        assertEq(uint8(factory.getMarket(market1).status), uint8(IMarketFactory.MarketStatus.Active));

        // Now resolve market 1 as NO
        _assertAndResolveMarket(market1, false, keccak256("assert-market-1"));

        // Both resolved
        assertEq(uint8(factory.getMarket(market0).status), uint8(IMarketFactory.MarketStatus.Resolved));
        assertEq(uint8(factory.getMarket(market1).status), uint8(IMarketFactory.MarketStatus.Resolved));
        assertTrue(resolver.isMarketResolved(market0));
        assertTrue(resolver.isMarketResolved(market1));
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    /// @dev Creates a market as `creator` with standard params
    function _createMarketAsCreator(
        string memory metadataURI,
        uint256 resolutionTimestamp,
        IMarketFactory.Category category
    ) internal returns (uint256) {
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId = factory.createMarket(metadataURI, resolutionTimestamp, category);
        vm.stopPrank();

        return marketId;
    }

    /// @dev Verifies assertion data is stored correctly
    function _verifyAssertionData(bytes32 assertionId, uint256 marketId) internal view {
        IClovOracleAdapter.Assertion memory assertion = oracleAdapter.getAssertion(assertionId);
        assertEq(assertion.marketId, marketId, "assertion marketId");
        assertEq(assertion.asserter, asserter, "assertion asserter");
        assertEq(assertion.outcome, true, "assertion outcome should be YES");
        assertFalse(assertion.settled, "assertion should not be settled yet");
        assertFalse(assertion.resolved, "assertion should not be resolved yet");
    }

    /// @dev Refunds creation deposit and verifies
    function _refundAndVerifyDeposit(uint256 marketId) internal {
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        factory.refundCreationDeposit(marketId);

        assertEq(
            usdc.balanceOf(creator), creatorBalanceBefore + CREATION_DEPOSIT, "creator should receive deposit back"
        );
        assertEq(factory.getMarket(marketId).creationDeposit, 0, "deposit should be zeroed out");
    }

    /// @dev Asserts and resolves a market in one step (mocks assertTruth with given ID)
    function _assertAndResolveMarket(uint256 marketId, bool outcome, bytes32 assertId) internal {
        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(assertId));

        usdc.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        oracleAdapter.assertOutcome(marketId, outcome, asserter);

        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertId, true);
    }
}
