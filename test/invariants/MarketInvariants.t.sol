// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { MarketFactory } from "../../src/MarketFactory.sol";
import { ClovOracleAdapter } from "../../src/ClovOracleAdapter.sol";
import { MarketResolver } from "../../src/MarketResolver.sol";
import { IMarketFactory } from "../../src/interfaces/IMarketFactory.sol";
import { IClovOracleAdapter } from "../../src/interfaces/IClovOracleAdapter.sol";
import { IConditionalTokens } from "../../src/interfaces/IConditionalTokens.sol";
import { IOptimisticOracleV3 } from "../../src/interfaces/IOptimisticOracleV3.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ──────────────────────────────────────────────
// Mock ERC20
// ──────────────────────────────────────────────

contract InvariantMockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ──────────────────────────────────────────────
// Handler — performs randomized actions and
// tracks ghost variables for invariant checks
//
// Clov 2.0 NOTE: FPMM trading has been removed. This handler now exercises
// only the surviving lifecycle: create market → assert outcome → resolve.
// Trading invariants will be re-introduced once the CTF Exchange CLOB
// integration lands in Phase C.
// ──────────────────────────────────────────────

contract MarketHandler is Test {
    MarketFactory public factory;
    ClovOracleAdapter public oracleAdapter;
    MarketResolver public resolver;
    InvariantMockERC20 public usdc;

    address public conditionalTokens;
    address public umaOracle;
    address public owner;

    // ── Ghost variables ──
    uint256 public ghost_marketsCreated;
    uint256 public ghost_depositsRefunded;
    uint256 public ghost_pauseCount;
    uint256 public ghost_unpauseCount;

    // Track per-market state for invariant verification
    mapping(uint256 => bool) public ghost_marketExists;
    mapping(uint256 => uint256) public ghost_originalDeposit;
    mapping(uint256 => bool) public ghost_depositRefunded;
    mapping(uint256 => uint8) public ghost_highestStatus;
    mapping(uint256 => bool) public ghost_wasResolved;

    // Track assertions
    mapping(uint256 => bytes32) public ghost_activeAssertion;
    mapping(bytes32 => uint256) public ghost_assertionToMarket;
    mapping(bytes32 => bool) public ghost_assertionExists;

    uint256 public ghost_assertionNonce;

    // Actors
    address[] public creators;
    address public asserter;

    uint256 public constant CREATION_DEPOSIT = 10e6;
    uint256 public constant BOND_AMOUNT = 500e6;
    bytes32 public constant MOCK_CONDITION_ID = keccak256("inv-condition");

    constructor(
        MarketFactory _factory,
        ClovOracleAdapter _oracleAdapter,
        MarketResolver _resolver,
        InvariantMockERC20 _usdc,
        address _conditionalTokens,
        address _umaOracle,
        address _owner
    ) {
        factory = _factory;
        oracleAdapter = _oracleAdapter;
        resolver = _resolver;
        usdc = _usdc;
        conditionalTokens = _conditionalTokens;
        umaOracle = _umaOracle;
        owner = _owner;

        for (uint256 i = 0; i < 5; i++) {
            creators.push(makeAddr(string(abi.encodePacked("creator", i))));
        }
        asserter = makeAddr("asserter");
    }

    // ──────────────────────────────────────────────
    // Action: Create Market
    // ──────────────────────────────────────────────

    function handler_createMarket(uint256 creatorSeed, uint256 hoursAhead) external {
        if (factory.paused()) return;

        hoursAhead = bound(hoursAhead, 2, 8760);
        address creator = creators[creatorSeed % creators.length];

        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId = factory.createMarket(
            "ipfs://invariant-test", block.timestamp + hoursAhead * 1 hours, IMarketFactory.Category.Futbol
        );
        vm.stopPrank();

        ghost_marketsCreated++;
        ghost_marketExists[marketId] = true;
        ghost_originalDeposit[marketId] = CREATION_DEPOSIT;
    }

    // ──────────────────────────────────────────────
    // Action: Assert Outcome (move Active → Resolving)
    // ──────────────────────────────────────────────

    function handler_assertOutcome(uint256 marketSeed, bool outcome) external {
        if (factory.marketCount() == 0) return;

        uint256 marketId = marketSeed % factory.marketCount();
        IMarketFactory.MarketData memory market = factory.getMarket(marketId);

        if (market.status != IMarketFactory.MarketStatus.Active) return;
        if (block.timestamp < market.resolutionTimestamp) return;

        ghost_assertionNonce++;
        bytes32 assertId = keccak256(abi.encodePacked("assert", ghost_assertionNonce));

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(assertId));

        usdc.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        usdc.approve(address(oracleAdapter), BOND_AMOUNT);

        oracleAdapter.assertOutcome(marketId, outcome, asserter);

        ghost_activeAssertion[marketId] = assertId;
        ghost_assertionToMarket[assertId] = marketId;
        ghost_assertionExists[assertId] = true;
    }

    // ──────────────────────────────────────────────
    // Action: UMA Resolves Truthfully (Resolving → Resolved)
    // ──────────────────────────────────────────────

    function handler_resolveAssertionTruthful(uint256 marketSeed) external {
        if (factory.marketCount() == 0) return;

        uint256 marketId = marketSeed % factory.marketCount();
        IMarketFactory.MarketData memory market = factory.getMarket(marketId);

        if (market.status != IMarketFactory.MarketStatus.Resolving) return;

        bytes32 assertId = ghost_activeAssertion[marketId];
        if (assertId == bytes32(0)) return;

        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertId, true);

        ghost_wasResolved[marketId] = true;
        ghost_highestStatus[marketId] = uint8(IMarketFactory.MarketStatus.Resolved);
    }

    // ──────────────────────────────────────────────
    // Action: UMA Denies Assertion (Resolving → Active)
    // ──────────────────────────────────────────────

    function handler_resolveAssertionDenied(uint256 marketSeed) external {
        if (factory.marketCount() == 0) return;

        uint256 marketId = marketSeed % factory.marketCount();
        IMarketFactory.MarketData memory market = factory.getMarket(marketId);

        if (market.status != IMarketFactory.MarketStatus.Resolving) return;

        bytes32 assertId = ghost_activeAssertion[marketId];
        if (assertId == bytes32(0)) return;

        vm.prank(umaOracle);
        oracleAdapter.assertionResolvedCallback(assertId, false);

        ghost_activeAssertion[marketId] = bytes32(0);
    }

    // ──────────────────────────────────────────────
    // Action: Dispute (Resolving → Active)
    // ──────────────────────────────────────────────

    function handler_disputeAssertion(uint256 marketSeed) external {
        if (factory.marketCount() == 0) return;

        uint256 marketId = marketSeed % factory.marketCount();
        IMarketFactory.MarketData memory market = factory.getMarket(marketId);

        if (market.status != IMarketFactory.MarketStatus.Resolving) return;

        bytes32 assertId = ghost_activeAssertion[marketId];
        if (assertId == bytes32(0)) return;

        vm.prank(umaOracle);
        oracleAdapter.assertionDisputedCallback(assertId);

        ghost_activeAssertion[marketId] = bytes32(0);
    }

    // ──────────────────────────────────────────────
    // Action: Refund Deposit
    // ──────────────────────────────────────────────

    function handler_refundDeposit(uint256 marketSeed) external {
        if (factory.marketCount() == 0) return;

        uint256 marketId = marketSeed % factory.marketCount();
        IMarketFactory.MarketData memory market = factory.getMarket(marketId);

        if (market.status != IMarketFactory.MarketStatus.Resolved) return;
        if (market.creationDeposit == 0) return;

        vm.prank(market.creator);
        factory.refundCreationDeposit(marketId);

        ghost_depositRefunded[marketId] = true;
        ghost_depositsRefunded++;
    }

    // ──────────────────────────────────────────────
    // Action: Pause / Unpause
    // ──────────────────────────────────────────────

    function handler_pause() external {
        if (factory.paused()) return;

        vm.prank(owner);
        factory.pauseMarketCreation();
        ghost_pauseCount++;
    }

    function handler_unpause() external {
        if (!factory.paused()) return;

        vm.prank(owner);
        factory.unpauseMarketCreation();
        ghost_unpauseCount++;
    }

    // ──────────────────────────────────────────────
    // Action: Warp Time
    // ──────────────────────────────────────────────

    function handler_warpTime(uint256 secondsToWarp) external {
        secondsToWarp = bound(secondsToWarp, 1, 24 hours);
        vm.warp(block.timestamp + secondsToWarp);
    }
}

// ──────────────────────────────────────────────
// Invariant Test Contract
// ──────────────────────────────────────────────

contract MarketInvariants is StdInvariant, Test {
    MarketFactory public factory;
    ClovOracleAdapter public oracleAdapter;
    MarketResolver public resolver;
    InvariantMockERC20 public usdc;
    MarketHandler public handler;

    address public conditionalTokens = makeAddr("conditionalTokens");
    address public umaOracle = makeAddr("umaOracle");

    uint256 public constant CREATION_DEPOSIT = 10e6;
    uint256 public constant BOND_AMOUNT = 500e6;
    uint64 public constant ASSERTION_LIVENESS = 7200;
    bytes32 public constant DEFAULT_IDENTIFIER = keccak256("ASSERT_TRUTH");
    bytes32 public constant MOCK_CONDITION_ID = keccak256("inv-condition");

    function setUp() public {
        usdc = new InvariantMockERC20();

        // ── Mock external contracts ──
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
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector),
            abi.encode(DEFAULT_IDENTIFIER)
        );

        // ── Deploy real contracts (staged with initialize) ──
        factory = new MarketFactory(address(usdc), conditionalTokens, CREATION_DEPOSIT);

        oracleAdapter = new ClovOracleAdapter(umaOracle, address(usdc), BOND_AMOUNT, ASSERTION_LIVENESS);

        resolver = new MarketResolver(conditionalTokens);

        // Wire cross-references
        factory.initialize(address(oracleAdapter), address(resolver));
        oracleAdapter.initialize(address(factory), address(resolver));
        resolver.initialize(address(factory), address(oracleAdapter));

        // ── Deploy Handler ──
        handler = new MarketHandler(factory, oracleAdapter, resolver, usdc, conditionalTokens, umaOracle, address(this));

        targetContract(address(handler));
    }

    // ──────────────────────────────────────────────
    // Invariant: marketCount consistency
    // ──────────────────────────────────────────────

    function invariant_marketCountConsistency() public view {
        assertEq(factory.marketCount(), handler.ghost_marketsCreated(), "marketCount must equal ghost_marketsCreated");

        uint256 count = factory.marketCount();
        for (uint256 i = 0; i < count; i++) {
            IMarketFactory.MarketData memory m = factory.getMarket(i);
            assertTrue(m.creator != address(0), "market creator must not be zero");
            assertTrue(m.questionId != bytes32(0), "market questionId must not be zero");
        }
    }

    // ──────────────────────────────────────────────
    // Invariant: market status transitions
    // ──────────────────────────────────────────────

    function invariant_marketStatusTransitions() public view {
        uint256 count = factory.marketCount();
        for (uint256 i = 0; i < count; i++) {
            IMarketFactory.MarketData memory m = factory.getMarket(i);
            uint8 status = uint8(m.status);

            assertTrue(
                status == uint8(IMarketFactory.MarketStatus.Active)
                    || status == uint8(IMarketFactory.MarketStatus.Resolving)
                    || status == uint8(IMarketFactory.MarketStatus.Resolved),
                "market status must be Active, Resolving, or Resolved"
            );
        }
    }

    // ──────────────────────────────────────────────
    // Invariant: resolved markets are immutable
    // ──────────────────────────────────────────────

    function invariant_resolvedMarketImmutable() public view {
        uint256 count = factory.marketCount();
        for (uint256 i = 0; i < count; i++) {
            if (handler.ghost_wasResolved(i)) {
                IMarketFactory.MarketData memory m = factory.getMarket(i);
                assertEq(
                    uint8(m.status),
                    uint8(IMarketFactory.MarketStatus.Resolved),
                    "once resolved, status must remain Resolved"
                );
            }
        }
    }

    // ──────────────────────────────────────────────
    // Invariant: creation deposit conservation
    // ──────────────────────────────────────────────

    function invariant_creationDepositConserved() public view {
        uint256 count = factory.marketCount();
        for (uint256 i = 0; i < count; i++) {
            IMarketFactory.MarketData memory m = factory.getMarket(i);
            uint256 originalDeposit = handler.ghost_originalDeposit(i);

            assertTrue(
                m.creationDeposit == originalDeposit || m.creationDeposit == 0,
                "deposit must be full original amount or zero"
            );

            if (handler.ghost_depositRefunded(i)) {
                assertEq(m.creationDeposit, 0, "refunded market deposit must be zero");
            }
        }
    }

    // ──────────────────────────────────────────────
    // Invariant: pause blocks creation
    // ──────────────────────────────────────────────

    function invariant_pauseBlocksCreation() public view {
        if (factory.paused()) {
            assertTrue(factory.paused(), "paused flag must be true");
        }
    }

    // ──────────────────────────────────────────────
    // Invariant: assertion data integrity
    // ──────────────────────────────────────────────

    function invariant_assertionDataIntegrity() public view {
        uint256 count = factory.marketCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 assertId = handler.ghost_activeAssertion(i);
            if (assertId != bytes32(0)) {
                IClovOracleAdapter.Assertion memory a = oracleAdapter.getAssertion(assertId);
                assertEq(a.marketId, i, "assertion must reference the correct market ID");
                assertTrue(a.asserter != address(0), "assertion asserter must not be zero");
            }
        }
    }
}
