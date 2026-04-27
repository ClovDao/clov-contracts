// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { ClovOracleAdapter } from "../src/ClovOracleAdapter.sol";
import { MarketResolver } from "../src/MarketResolver.sol";
import { MarketRewards } from "../src/MarketRewards.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IClovOracleAdapter } from "../src/interfaces/IClovOracleAdapter.sol";
import { IMarketRewards } from "../src/interfaces/IMarketRewards.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";
import { IOptimisticOracleV3 } from "../src/interfaces/IOptimisticOracleV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC with public mint and 6 decimals
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title E2EClovV2 — Full lifecycle integration test
/// @notice Exercises the complete flow across all core Clov contracts:
///         MarketFactory, ClovOracleAdapter, MarketResolver, and MarketRewards.
///
/// @dev CTF Exchange order matching is NOT tested here. The exchange is a complex Polymarket fork
///      with many dependencies (Auth, Signatures, EIP-712, Safe wallet factory, ERC-1155 approvals)
///      that would require extensive mock scaffolding. Exchange matching is tested separately in its
///      own test suite. This test focuses on contract INTERACTIONS across the core lifecycle:
///
///      1. Deploy all contracts
///      2. Create market via MarketFactory
///      3. Sponsor deposits rewards via MarketRewards
///      4. Oracle assertion (mock UMA resolution)
///      5. Market resolves via MarketResolver
///      6. Traders redeem ConditionalTokens (mocked)
///      7. Maker claims rewards via merkle proof
///      8. Sponsor withdraws unused rewards after end date
///      9. Creator reclaims creation deposit
contract E2EClovV2 is Test {
    // ──────────────────────────────────────────────
    // Contracts
    // ──────────────────────────────────────────────

    MarketFactory public factory;
    ClovOracleAdapter public oracleAdapter;
    MarketResolver public resolver;
    MarketRewards public rewards;
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
    address public sponsor = makeAddr("sponsor");
    address public traderYes = makeAddr("traderYes");
    address public traderNo = makeAddr("traderNo");
    address public maker1 = makeAddr("maker1");
    address public asserter = makeAddr("asserter");

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 public constant CREATION_DEPOSIT = 10e6; // 10 USDC
    uint256 public constant BOND_AMOUNT = 500e6; // 500 USDC
    uint256 public constant CHALLENGE_BOND_AMOUNT = 500e6;
    uint64 public constant ASSERTION_LIVENESS = 7200; // 2 hours
    bytes32 public constant DEFAULT_IDENTIFIER = keccak256("ASSERT_TRUTH");
    bytes32 public constant MOCK_CONDITION_ID = keccak256("e2e-condition-0");
    bytes32 public constant MOCK_ASSERTION_ID = keccak256("e2e-assertion-0");

    uint256 public constant SPONSOR_DEPOSIT = 1000e6; // 1000 USDC
    uint256 public constant SPONSOR_DURATION_DAYS = 30;

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
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.redeemPositions.selector), abi.encode()
        );

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

        // ── Deploy real Clov contracts ──
        factory = new MarketFactory(address(usdc), conditionalTokens, ctfExchange, CREATION_DEPOSIT);
        oracleAdapter =
            new ClovOracleAdapter(umaOracle, address(usdc), BOND_AMOUNT, CHALLENGE_BOND_AMOUNT, ASSERTION_LIVENESS);
        resolver = new MarketResolver(conditionalTokens);
        rewards = new MarketRewards(address(usdc), deployer);

        // Wire cross-references
        factory.initialize(address(oracleAdapter), address(resolver));
        oracleAdapter.initialize(address(factory), address(resolver));
        resolver.initialize(address(factory), address(oracleAdapter));

        // Allow asserter to call assertOutcome
        oracleAdapter.addAsserter(asserter);
    }

    // ──────────────────────────────────────────────
    // Full Lifecycle: Market + Rewards + Resolution
    // ──────────────────────────────────────────────

    /// @notice Tests the complete lifecycle across all core contracts
    function test_e2e_fullClovV2Lifecycle() public {
        // ════════════════════════════════════════════
        // STEP 1: Create market via MarketFactory
        // ════════════════════════════════════════════

        uint256 marketId = _createMarket("ipfs://e2e-match", IMarketFactory.Category.Futbol);

        assertEq(marketId, 0, "first market should be id 0");
        assertEq(factory.marketCount(), 1, "market count should be 1");

        {
            IMarketFactory.MarketData memory market = factory.getMarket(marketId);
            assertEq(uint8(market.status), uint8(IMarketFactory.MarketStatus.Active), "market should be Active");
            assertEq(market.creator, creator, "creator mismatch");
            assertEq(market.conditionId, MOCK_CONDITION_ID, "conditionId mismatch");
        }

        // ════════════════════════════════════════════
        // STEP 2: Sponsor deposits rewards for the market
        // ════════════════════════════════════════════

        bytes32 rewardsMarketId = keccak256(abi.encodePacked("market-", marketId));
        _depositSponsorRewards(rewardsMarketId);

        {
            (uint256 amount,, uint256 startedAt, uint256 endsAt, bool withdrawn) =
                rewards.sponsorDeposits(rewardsMarketId, sponsor);

            assertEq(amount, SPONSOR_DEPOSIT, "sponsor deposit amount");
            assertTrue(startedAt > 0, "sponsor startedAt should be set");
            assertEq(endsAt, startedAt + (SPONSOR_DURATION_DAYS * 1 days), "sponsor endsAt");
            assertFalse(withdrawn, "sponsor should not be withdrawn");
        }

        assertEq(usdc.balanceOf(sponsor), 0, "sponsor should have 0 USDC");

        // ════════════════════════════════════════════
        // STEP 3: (Skipped) CTF Exchange order matching
        // ════════════════════════════════════════════
        // CTF Exchange matching requires complex setup (EIP-712 signatures, operator roles,
        // token registration, ERC-1155 approvals). It is tested in its own dedicated suite.

        // ════════════════════════════════════════════
        // STEP 4: Oracle assertion (YES wins)
        // ════════════════════════════════════════════

        vm.warp(factory.getMarket(marketId).resolutionTimestamp + 1);

        bytes32 assertionId = _assertOutcome(marketId, true);

        assertEq(assertionId, MOCK_ASSERTION_ID, "assertionId should match mock");
        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolving),
            "market should be Resolving"
        );

        // ════════════════════════════════════════════
        // STEP 5: UMA confirms -> market resolves via MarketResolver
        // ════════════════════════════════════════════

        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertionId, true);

        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolved),
            "market should be Resolved"
        );
        assertTrue(resolver.isMarketResolved(marketId), "resolver should mark market as resolved");

        // ════════════════════════════════════════════
        // STEP 6: Traders redeem ConditionalTokens (mocked)
        // ════════════════════════════════════════════

        _redeemPositions(traderYes);

        // ════════════════════════════════════════════
        // STEP 7: Maker claims rewards via merkle proof
        // ════════════════════════════════════════════

        _claimMakerRewards();

        // ════════════════════════════════════════════
        // STEP 8: Sponsor withdraws unused rewards after end date
        // ════════════════════════════════════════════

        vm.warp(block.timestamp + (SPONSOR_DURATION_DAYS * 1 days) + 1);

        _withdrawSponsorAndVerify(rewardsMarketId);

        // ════════════════════════════════════════════
        // STEP 9: Creator reclaims creation deposit
        // ════════════════════════════════════════════

        _refundAndVerifyDeposit(marketId);
    }

    // ──────────────────────────────────────────────
    // Cross-contract access control integration
    // ──────────────────────────────────────────────

    /// @notice Verifies that only authorized contracts can call each other
    function test_e2e_crossContractAccessControl() public {
        // Create a market first
        usdc.mint(creator, CREATION_DEPOSIT);
        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);
        factory.createMarket("ipfs://access-control", block.timestamp + 2 hours, IMarketFactory.Category.Esports);
        vm.stopPrank();

        // Random address cannot resolve via MarketResolver
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(traderYes);
        vm.expectRevert(MarketResolver.OnlyOracleAdapter.selector);
        resolver.resolve(0, payouts);

        // Random address cannot call UMA callback on adapter
        vm.prank(traderYes);
        vm.expectRevert(ClovOracleAdapter.OnlyUmaOracle.selector);
        oracleAdapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);

        // Non-allowed asserter cannot call assertOutcome
        vm.prank(traderYes);
        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.UnauthorizedAsserter.selector, traderYes));
        oracleAdapter.assertOutcome(0, true, traderYes);

        // Random address cannot update market status on factory
        vm.prank(traderYes);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.UnauthorizedStatusUpdate.selector, traderYes));
        factory.updateMarketStatus(0, IMarketFactory.MarketStatus.Resolved);
    }

    // ──────────────────────────────────────────────
    // Rewards lifecycle independent of market resolution
    // ──────────────────────────────────────────────

    /// @notice Tests that the rewards system works independently: deposit → claim → withdraw
    function test_e2e_rewardsLifecycleStandalone() public {
        bytes32 mktId = keccak256("standalone-market");

        // Sponsor deposits
        usdc.mint(sponsor, SPONSOR_DEPOSIT);
        vm.startPrank(sponsor);
        usdc.approve(address(rewards), SPONSOR_DEPOSIT);
        rewards.depositSponsorRewards(mktId, SPONSOR_DEPOSIT, SPONSOR_DURATION_DAYS);
        vm.stopPrank();

        // Fund rewards contract for claims
        uint256 claimAmount = 200e6;
        usdc.mint(address(rewards), claimAmount);

        // Build merkle tree and set root (single leaf + dummy)
        bytes32 leaf1 = keccak256(abi.encodePacked(maker1, claimAmount));
        bytes32 dummyLeaf = keccak256(abi.encodePacked(address(0xdead), uint256(0)));
        bytes32 root = _hashPair(leaf1, dummyLeaf);

        rewards.updateMerkleRoot(root);

        // Maker claims
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = dummyLeaf;

        vm.prank(maker1);
        rewards.claimRewards(claimAmount, proof);

        assertEq(usdc.balanceOf(maker1), claimAmount, "maker1 should have claimed amount");

        // Double claim reverts
        vm.prank(maker1);
        vm.expectRevert(MarketRewards.NothingToClaim.selector);
        rewards.claimRewards(claimAmount, proof);

        // Sponsor cannot withdraw before end date
        (,,, uint256 endsAt,) = rewards.sponsorDeposits(mktId, sponsor);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(MarketRewards.SponsorPeriodNotEnded.selector, mktId, endsAt));
        rewards.withdrawUnusedSponsor(mktId);

        // Warp past end date and withdraw
        vm.warp(endsAt + 1);

        vm.prank(sponsor);
        rewards.withdrawUnusedSponsor(mktId);

        assertEq(usdc.balanceOf(sponsor), SPONSOR_DEPOSIT, "sponsor should recover full deposit");
    }

    // ──────────────────────────────────────────────
    // Dispute cycle then resolve
    // ──────────────────────────────────────────────

    /// @notice Tests a disputed assertion resetting the market, followed by successful resolution
    function test_e2e_disputeThenResolve() public {
        // Create market
        usdc.mint(creator, CREATION_DEPOSIT);
        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);
        uint256 marketId =
            factory.createMarket("ipfs://e2e-dispute", block.timestamp + 2 hours, IMarketFactory.Category.Esports);
        vm.stopPrank();

        // Warp past resolution
        vm.warp(factory.getMarket(marketId).resolutionTimestamp + 1);

        // First assertion: YES (will be denied)
        usdc.mint(asserter, BOND_AMOUNT);
        vm.startPrank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        bytes32 firstAssertionId = oracleAdapter.assertOutcome(marketId, true, asserter);
        vm.stopPrank();

        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolving),
            "should be Resolving after first assertion"
        );

        // UMA denies the assertion
        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(firstAssertionId, false);

        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Active),
            "should be Active after denied assertion"
        );

        // Second assertion: NO (will be confirmed)
        bytes32 secondAssertionId = keccak256("e2e-second-assertion");
        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(secondAssertionId)
        );

        usdc.mint(asserter, BOND_AMOUNT);
        vm.startPrank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        bytes32 newAssertionId = oracleAdapter.assertOutcome(marketId, false, asserter);
        vm.stopPrank();

        assertEq(newAssertionId, secondAssertionId, "should use new assertion ID");

        // UMA confirms
        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(secondAssertionId, true);

        assertEq(
            uint8(factory.getMarket(marketId).status),
            uint8(IMarketFactory.MarketStatus.Resolved),
            "should be Resolved after confirmed second assertion"
        );
        assertTrue(resolver.isMarketResolved(marketId), "resolver should mark resolved");

        // Creator can reclaim deposit
        vm.prank(creator);
        factory.refundCreationDeposit(marketId);

        assertEq(factory.getMarket(marketId).creationDeposit, 0, "deposit should be zeroed");
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    /// @dev Creates a market as `creator` with standard params
    function _createMarket(string memory metadataURI, IMarketFactory.Category category) internal returns (uint256) {
        usdc.mint(creator, CREATION_DEPOSIT);
        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);
        uint256 marketId = factory.createMarket(metadataURI, block.timestamp + 2 hours, category);
        vm.stopPrank();
        return marketId;
    }

    /// @dev Deposits sponsor rewards for a given market
    function _depositSponsorRewards(bytes32 rewardsMarketId) internal {
        usdc.mint(sponsor, SPONSOR_DEPOSIT);
        vm.startPrank(sponsor);
        usdc.approve(address(rewards), SPONSOR_DEPOSIT);
        rewards.depositSponsorRewards(rewardsMarketId, SPONSOR_DEPOSIT, SPONSOR_DURATION_DAYS);
        vm.stopPrank();
    }

    /// @dev Asserts an outcome as the asserter and returns the assertion ID
    function _assertOutcome(uint256 marketId, bool outcome) internal returns (bytes32) {
        usdc.mint(asserter, BOND_AMOUNT);
        vm.startPrank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);
        bytes32 assertionId = oracleAdapter.assertOutcome(marketId, outcome, asserter);
        vm.stopPrank();
        return assertionId;
    }

    /// @dev Calls redeemPositions on the mocked ConditionalTokens
    function _redeemPositions(address trader) internal {
        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1;
        indexSets[1] = 2;
        vm.prank(trader);
        IConditionalTokens(conditionalTokens)
            .redeemPositions(IERC20(address(usdc)), bytes32(0), MOCK_CONDITION_ID, indexSets);
    }

    /// @dev Funds rewards contract, builds merkle tree, and has maker1 claim
    function _claimMakerRewards() internal {
        uint256 maker1Reward = 100e6;
        uint256 maker2Reward = 50e6;
        usdc.mint(address(rewards), maker1Reward + maker2Reward);

        bytes32 leaf1 = keccak256(abi.encodePacked(maker1, maker1Reward));
        bytes32 leaf2 = keccak256(abi.encodePacked(traderNo, maker2Reward));
        bytes32 root = _hashPair(leaf1, leaf2);

        rewards.updateMerkleRoot(root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        uint256 balBefore = usdc.balanceOf(maker1);
        vm.prank(maker1);
        rewards.claimRewards(maker1Reward, proof);

        assertEq(usdc.balanceOf(maker1), balBefore + maker1Reward, "maker1 should receive reward");
        assertEq(rewards.claimed(maker1), maker1Reward, "maker1 claimed amount should be tracked");
    }

    /// @dev Withdraws sponsor deposit and verifies
    function _withdrawSponsorAndVerify(bytes32 rewardsMarketId) internal {
        uint256 balBefore = usdc.balanceOf(sponsor);
        vm.prank(sponsor);
        rewards.withdrawUnusedSponsor(rewardsMarketId);
        assertEq(usdc.balanceOf(sponsor), balBefore + SPONSOR_DEPOSIT, "sponsor should recover deposit");

        (,,,, bool withdrawn) = rewards.sponsorDeposits(rewardsMarketId, sponsor);
        assertTrue(withdrawn, "sponsor deposit should be marked withdrawn");
    }

    /// @dev Refunds creation deposit and verifies
    function _refundAndVerifyDeposit(uint256 marketId) internal {
        uint256 balBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        factory.refundCreationDeposit(marketId);
        assertEq(usdc.balanceOf(creator), balBefore + CREATION_DEPOSIT, "creator should receive deposit back");
        assertEq(factory.getMarket(marketId).creationDeposit, 0, "deposit should be zeroed out");
    }

    /// @dev Sorted pair hash for merkle tree construction
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        if (a < b) {
            return keccak256(abi.encodePacked(a, b));
        } else {
            return keccak256(abi.encodePacked(b, a));
        }
    }
}
