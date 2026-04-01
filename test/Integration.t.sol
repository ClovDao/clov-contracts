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
import { IFPMMDeterministicFactory } from "../src/interfaces/IFPMMDeterministicFactory.sol";
import { IOptimisticOracleV3 } from "../src/interfaces/IOptimisticOracleV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC with public mint
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title IntegrationTest — Full lifecycle of a Clov prediction market
/// @notice Tests the complete flow: create market → trade → assert → UMA callback → resolve → redeem
/// @dev Uses REAL Clov contracts (MarketFactory, ClovOracleAdapter, MarketResolver) with mocked
///      external dependencies (Gnosis ConditionalTokens, FPMM, UMA Oracle) since Gnosis contracts
///      are Solidity 0.5.x and cannot be co-compiled with 0.8.24.
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
    address public fpmmFactory = makeAddr("fpmmFactory");
    address public umaOracle = makeAddr("umaOracle");
    address public mockFpmm = makeAddr("mockFpmm");

    // ──────────────────────────────────────────────
    // Actors
    // ──────────────────────────────────────────────

    address public deployer;
    address public creator = makeAddr("creator");
    address public user1 = makeAddr("user1"); // YES buyer
    address public user2 = makeAddr("user2"); // NO buyer
    address public asserter = makeAddr("asserter");

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 public constant CREATION_DEPOSIT = 10e6; // 10 USDC
    uint256 public constant TRADING_FEE = 100; // 1% BPS
    uint256 public constant INITIAL_LIQUIDITY = 1000e6; // 1000 USDC
    uint256 public constant BOND_AMOUNT = 500e6; // 500 USDC
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
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector),
            abi.encode()
        );
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getConditionId.selector),
            abi.encode(MOCK_CONDITION_ID)
        );
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.reportPayouts.selector),
            abi.encode()
        );

        // ── Mock FPMM Factory ──
        vm.mockCall(
            fpmmFactory,
            abi.encodeWithSelector(IFPMMDeterministicFactory.create2FixedProductMarketMaker.selector),
            abi.encode(mockFpmm)
        );

        // ── Mock UMA Oracle ──
        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector),
            abi.encode(DEFAULT_IDENTIFIER)
        );
        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector),
            abi.encode(MOCK_ASSERTION_ID)
        );

        // ── Deploy real Clov contracts ──
        uint64 deployerNonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, deployerNonce);
        address predictedAdapter = vm.computeCreateAddress(deployer, deployerNonce + 1);
        address predictedResolver = vm.computeCreateAddress(deployer, deployerNonce + 2);

        factory = new MarketFactory(
            address(usdc),
            conditionalTokens,
            fpmmFactory,
            predictedAdapter,
            predictedResolver,
            CREATION_DEPOSIT,
            TRADING_FEE
        );

        oracleAdapter = new ClovOracleAdapter(
            umaOracle,
            address(usdc),
            address(factory),
            predictedResolver,
            BOND_AMOUNT,
            ASSERTION_LIVENESS
        );

        resolver = new MarketResolver(conditionalTokens, address(factory), address(oracleAdapter));

        // Sanity: verify predicted addresses match
        assertEq(address(factory), predictedFactory, "factory address mismatch");
        assertEq(address(oracleAdapter), predictedAdapter, "adapter address mismatch");
        assertEq(address(resolver), predictedResolver, "resolver address mismatch");
    }

    // ──────────────────────────────────────────────
    // Full Lifecycle Test
    // ──────────────────────────────────────────────

    function test_fullLifecycle_createTradeAssertResolveRedeem() public {
        // PHASE 1: Create Market
        uint256 marketId = _createMarketAsCreator(
            "ipfs://will-team-a-win",
            block.timestamp + 2 hours,
            IMarketFactory.Category.Sports
        );

        assertEq(marketId, 0, "first market should be id 0");
        assertEq(factory.marketCount(), 1, "market count should be 1");

        {
            IMarketFactory.MarketData memory market = factory.getMarket(marketId);
            assertEq(uint8(market.status), uint8(IMarketFactory.MarketStatus.Active), "market should be Active");
            assertEq(market.creator, creator, "creator mismatch");
            assertEq(market.fpmm, mockFpmm, "fpmm address mismatch");
            assertEq(market.conditionId, MOCK_CONDITION_ID, "conditionId mismatch");
            assertTrue(market.questionId != bytes32(0), "questionId should not be zero");
        }

        // Factory should hold the creation deposit + initial liquidity
        // (FPMM factory is mocked so it doesn't actually pull the liquidity)
        assertEq(
            usdc.balanceOf(address(factory)),
            CREATION_DEPOSIT + INITIAL_LIQUIDITY,
            "factory should hold deposit + liquidity (mocked FPMM)"
        );
        // Creator should have 0 left
        assertEq(usdc.balanceOf(creator), 0, "creator should have spent everything");

        // PHASE 2 & 3: Trade
        _simulateTrades();

        // PHASE 4: Verify prices changed (via mock)
        _verifyPricesShifted();

        // PHASE 5: Assert outcome (YES wins)
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

        // PHASE 6: UMA confirms truth → resolve
        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertionId, true);

        // PHASE 7: Verify market is Resolved
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

        // PHASE 8: Winner redeems — User1 (YES holder)
        _redeemAndVerifyWinner(marketId);

        // PHASE 9: Loser gets nothing — User2 (NO holder)
        _redeemAndVerifyLoser(marketId);

        // PHASE 10: Creator reclaims deposit
        _refundAndVerifyDeposit(marketId);
    }

    // ──────────────────────────────────────────────
    // Lifecycle with dispute (assertion denied)
    // ──────────────────────────────────────────────

    function test_lifecycle_assertionDenied_marketResetsToActive() public {
        // Create market
        uint256 marketId = _createMarketAsCreator(
            "ipfs://disputed-market",
            block.timestamp + 2 hours,
            IMarketFactory.Category.Gaming
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
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector),
            abi.encode(secondAssertionId)
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
        uint256 totalCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;

        usdc.mint(creator, totalCost * 2);
        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost * 2);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 market0 = factory.createMarket(
            "ipfs://market-0", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds
        );
        uint256 market1 = factory.createMarket(
            "ipfs://market-1", block.timestamp + 3 hours, IMarketFactory.Category.Gaming, INITIAL_LIQUIDITY, odds
        );
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

    /// @dev Returns index sets for binary outcome [0b01, 0b10] = [1, 2]
    function _indexSets() internal pure returns (uint256[] memory) {
        uint256[] memory sets = new uint256[](2);
        sets[0] = 1; // YES = 0b01
        sets[1] = 2; // NO  = 0b10
        return sets;
    }

    /// @dev Creates a market as `creator` with standard params
    function _createMarketAsCreator(
        string memory metadataURI,
        uint256 resolutionTimestamp,
        IMarketFactory.Category category
    ) internal returns (uint256) {
        uint256 totalCreationCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;
        usdc.mint(creator, totalCreationCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCreationCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId = factory.createMarket(
            metadataURI,
            resolutionTimestamp,
            category,
            INITIAL_LIQUIDITY,
            odds
        );
        vm.stopPrank();

        return marketId;
    }

    /// @dev Simulates user1 buying YES and user2 buying NO via mocked FPMM
    function _simulateTrades() internal {
        uint256 user1Investment = 200e6;
        usdc.mint(user1, user1Investment);

        vm.mockCall(
            mockFpmm,
            abi.encodeWithSignature("buy(uint256,uint256,uint256)", user1Investment, 0, 0),
            abi.encode(user1Investment)
        );

        vm.startPrank(user1);
        usdc.approve(mockFpmm, user1Investment);
        (bool success,) = mockFpmm.call(
            abi.encodeWithSignature("buy(uint256,uint256,uint256)", user1Investment, 0, uint256(0))
        );
        assertTrue(success, "user1 buy YES should succeed");
        vm.stopPrank();

        uint256 user2Investment = 100e6;
        usdc.mint(user2, user2Investment);

        vm.mockCall(
            mockFpmm,
            abi.encodeWithSignature("buy(uint256,uint256,uint256)", user2Investment, 1, 0),
            abi.encode(user2Investment)
        );

        vm.startPrank(user2);
        usdc.approve(mockFpmm, user2Investment);
        (success,) = mockFpmm.call(
            abi.encodeWithSignature("buy(uint256,uint256,uint256)", user2Investment, 1, uint256(0))
        );
        assertTrue(success, "user2 buy NO should succeed");
        vm.stopPrank();
    }

    /// @dev Verifies that mocked prices shifted after asymmetric trades
    function _verifyPricesShifted() internal {
        uint256 testAmount = 100e6;
        vm.mockCall(
            mockFpmm,
            abi.encodeWithSignature("calcBuyAmount(uint256,uint256)", testAmount, 0),
            abi.encode(80e6)
        );
        vm.mockCall(
            mockFpmm,
            abi.encodeWithSignature("calcBuyAmount(uint256,uint256)", testAmount, 1),
            abi.encode(130e6)
        );

        (, bytes memory yesData) = mockFpmm.staticcall(
            abi.encodeWithSignature("calcBuyAmount(uint256,uint256)", testAmount, 0)
        );
        (, bytes memory noData) = mockFpmm.staticcall(
            abi.encodeWithSignature("calcBuyAmount(uint256,uint256)", testAmount, 1)
        );

        uint256 yesBuyAmount = abi.decode(yesData, (uint256));
        uint256 noBuyAmount = abi.decode(noData, (uint256));

        assertTrue(yesBuyAmount < noBuyAmount, "YES should be more expensive than NO after trades");
        assertTrue(yesBuyAmount < testAmount, "YES price should be above 0.5 (fewer tokens per USDC)");
        assertTrue(noBuyAmount > testAmount, "NO price should be below 0.5 (more tokens per USDC)");
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

    /// @dev Simulates winner (user1) redeeming YES tokens
    function _redeemAndVerifyWinner(uint256 marketId) internal {
        bytes32 conditionId = factory.getMarket(marketId).conditionId;
        bytes32 parentCollectionId = bytes32(0);

        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSignature(
                "redeemPositions(address,bytes32,bytes32,uint256[])",
                address(usdc), parentCollectionId, conditionId, _indexSets()
            ),
            abi.encode()
        );

        vm.prank(user1);
        (bool success,) = conditionalTokens.call(
            abi.encodeWithSignature(
                "redeemPositions(address,bytes32,bytes32,uint256[])",
                address(usdc), parentCollectionId, conditionId, _indexSets()
            )
        );
        assertTrue(success, "user1 redeemPositions should succeed");

        // Simulate the USDC payout (in reality CT would transfer)
        // User1 held YES tokens which won, so they get their investment value
        uint256 user1Investment = 200e6;
        uint256 balBefore = usdc.balanceOf(user1);
        usdc.mint(user1, user1Investment); // simulate CT payout
        assertEq(usdc.balanceOf(user1) - balBefore, user1Investment, "user1 should receive their payout");
    }

    /// @dev Simulates loser (user2) redeeming NO tokens (gets nothing)
    function _redeemAndVerifyLoser(uint256 marketId) internal {
        bytes32 conditionId = factory.getMarket(marketId).conditionId;
        bytes32 parentCollectionId = bytes32(0);

        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSignature(
                "redeemPositions(address,bytes32,bytes32,uint256[])",
                address(usdc), parentCollectionId, conditionId, _indexSets()
            ),
            abi.encode()
        );

        uint256 user2BalanceBefore = usdc.balanceOf(user2);
        vm.prank(user2);
        (bool success,) = conditionalTokens.call(
            abi.encodeWithSignature(
                "redeemPositions(address,bytes32,bytes32,uint256[])",
                address(usdc), parentCollectionId, conditionId, _indexSets()
            )
        );
        assertTrue(success, "user2 redeemPositions call should succeed");

        assertEq(usdc.balanceOf(user2), user2BalanceBefore, "user2 (loser) should get nothing");
    }

    /// @dev Refunds creation deposit and verifies
    function _refundAndVerifyDeposit(uint256 marketId) internal {
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        factory.refundCreationDeposit(marketId);

        assertEq(
            usdc.balanceOf(creator),
            creatorBalanceBefore + CREATION_DEPOSIT,
            "creator should receive deposit back"
        );
        assertEq(factory.getMarket(marketId).creationDeposit, 0, "deposit should be zeroed out");
    }

    /// @dev Asserts and resolves a market in one step (mocks assertTruth with given ID)
    function _assertAndResolveMarket(uint256 marketId, bool outcome, bytes32 assertId) internal {
        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector),
            abi.encode(assertId)
        );

        usdc.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        oracleAdapter.assertOutcome(marketId, outcome, asserter);

        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertId, true);
    }
}
