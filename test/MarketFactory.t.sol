// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";
import { IFPMMDeterministicFactory } from "../src/interfaces/IFPMMDeterministicFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Harness that exposes internal state manipulation for testing
contract MarketFactoryHarness is MarketFactory {
    constructor(
        address _collateralToken,
        address _conditionalTokens,
        address _fpmmFactory,
        uint256 _creationDeposit,
        uint256 _tradingFee
    )
        MarketFactory(
            _collateralToken, _conditionalTokens, _fpmmFactory, _creationDeposit, _tradingFee
        )
    {}

    function setMarketStatus(uint256 marketId, MarketStatus status) external {
        markets[marketId].status = status;
    }
}

contract MarketFactoryTest is Test {
    MarketFactoryHarness public factory;
    MockERC20 public usdc;

    address public owner;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public conditionalTokens = makeAddr("conditionalTokens");
    address public fpmmFactory = makeAddr("fpmmFactory");
    address public oracleAdapter = makeAddr("oracleAdapter");
    address public marketResolver = makeAddr("marketResolver");
    address public mockFpmm = makeAddr("mockFpmm");

    uint256 public constant CREATION_DEPOSIT = 10e6; // 10 USDC
    uint256 public constant TRADING_FEE = 100; // 1% in BPS
    uint256 public constant INITIAL_LIQUIDITY = 100e6; // 100 USDC

    bytes32 public constant MOCK_CONDITION_ID = keccak256("mockConditionId");

    function setUp() public {
        owner = address(this);
        usdc = new MockERC20();

        factory = new MarketFactoryHarness(
            address(usdc), conditionalTokens, fpmmFactory, CREATION_DEPOSIT, TRADING_FEE
        );
        factory.initialize(oracleAdapter, marketResolver);

        // Mock ConditionalTokens.prepareCondition — just succeed
        vm.mockCall(conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode());

        // Mock ConditionalTokens.getConditionId — return fixed conditionId
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getConditionId.selector),
            abi.encode(MOCK_CONDITION_ID)
        );

        // Mock FPMMFactory.create2FixedProductMarketMaker — return mock FPMM address
        vm.mockCall(
            fpmmFactory,
            abi.encodeWithSelector(IFPMMDeterministicFactory.create2FixedProductMarketMaker.selector),
            abi.encode(mockFpmm)
        );
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_setsStateCorrectly() public view {
        assertEq(address(factory.collateralToken()), address(usdc));
        assertEq(address(factory.conditionalTokens()), conditionalTokens);
        assertEq(address(factory.fpmmFactory()), fpmmFactory);
        assertEq(factory.oracleAdapter(), oracleAdapter);
        assertEq(factory.marketResolver(), marketResolver);
        assertEq(factory.creationDeposit(), CREATION_DEPOSIT);
        assertEq(factory.tradingFee(), TRADING_FEE);
        assertEq(factory.marketCount(), 0);
        assertEq(factory.owner(), owner);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactoryHarness(address(0), conditionalTokens, fpmmFactory, CREATION_DEPOSIT, TRADING_FEE);

        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactoryHarness(address(usdc), address(0), fpmmFactory, CREATION_DEPOSIT, TRADING_FEE);

        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactoryHarness(address(usdc), conditionalTokens, address(0), CREATION_DEPOSIT, TRADING_FEE);
    }

    function test_initialize_revertsOnZeroAddress() public {
        MarketFactoryHarness f = new MarketFactoryHarness(address(usdc), conditionalTokens, fpmmFactory, CREATION_DEPOSIT, TRADING_FEE);

        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        f.initialize(address(0), marketResolver);

        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        f.initialize(oracleAdapter, address(0));
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert(MarketFactory.AlreadyInitialized.selector);
        factory.initialize(oracleAdapter, marketResolver);
    }

    // ──────────────────────────────────────────────
    // createMarket
    // ──────────────────────────────────────────────

    function _createDefaultMarket(address creator) internal returns (uint256) {
        uint256 totalCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId = factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();

        return marketId;
    }

    function test_createMarket_happyPath() public {
        uint256 marketId = _createDefaultMarket(alice);

        assertEq(marketId, 0);
        assertEq(factory.marketCount(), 1);

        IMarketFactory.MarketData memory m = factory.getMarket(0);
        assertEq(m.creator, alice);
        assertEq(m.fpmm, mockFpmm);
        assertEq(m.conditionId, MOCK_CONDITION_ID);
        assertEq(m.metadataURI, "ipfs://metadata");
        assertEq(m.creationDeposit, CREATION_DEPOSIT);
        assertEq(m.resolutionTimestamp, block.timestamp + 2 hours);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Active));
        assertEq(uint8(m.category), uint8(IMarketFactory.Category.Sports));
    }

    function test_createMarket_incrementsMarketCount() public {
        _createDefaultMarket(alice);
        _createDefaultMarket(bob);

        assertEq(factory.marketCount(), 2);
        assertEq(factory.getMarket(0).creator, alice);
        assertEq(factory.getMarket(1).creator, bob);
    }

    function test_createMarket_emitsMarketCreated() public {
        uint256 totalCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;
        usdc.mint(alice, totalCost);

        vm.startPrank(alice);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        // Check that MarketCreated is emitted (check topic1 = marketId=0 and topic2 = creator=alice)
        vm.expectEmit(true, true, false, false);
        emit IMarketFactory.MarketCreated(
            0, alice, mockFpmm, MOCK_CONDITION_ID, bytes32(0), "ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY
        );

        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();
    }

    function test_createMarket_transfersTokensFromCreator() public {
        uint256 totalCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;
        usdc.mint(alice, totalCost);

        vm.startPrank(alice);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();

        // Alice should have 0 USDC left (deposit + liquidity transferred)
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_createMarket_revertsInvalidTimestamp() public {
        usdc.mint(alice, CREATION_DEPOSIT + INITIAL_LIQUIDITY);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT + INITIAL_LIQUIDITY);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        // Timestamp in the past
        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createMarket("ipfs://metadata", block.timestamp, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);

        // Timestamp exactly 1 hour from now (needs to be MORE than 1 hour)
        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 1 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);

        vm.stopPrank();
    }

    function test_createMarket_revertsZeroLiquidity() public {
        usdc.mint(alice, CREATION_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        vm.expectRevert(MarketFactory.InsufficientInitialLiquidity.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, 0, odds);

        vm.stopPrank();
    }

    function test_createMarket_revertsWhenPaused() public {
        factory.pauseMarketCreation();

        usdc.mint(alice, CREATION_DEPOSIT + INITIAL_LIQUIDITY);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT + INITIAL_LIQUIDITY);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // pauseMarketCreation / unpauseMarketCreation
    // ──────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.pauseMarketCreation();
    }

    function test_unpause_onlyOwner() public {
        factory.pauseMarketCreation();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.unpauseMarketCreation();
    }

    function test_pause_blocksCreateMarket() public {
        factory.pauseMarketCreation();

        usdc.mint(alice, CREATION_DEPOSIT + INITIAL_LIQUIDITY);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT + INITIAL_LIQUIDITY);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();
    }

    function test_unpause_allowsCreateMarket() public {
        factory.pauseMarketCreation();
        factory.unpauseMarketCreation();

        uint256 marketId = _createDefaultMarket(alice);
        assertEq(marketId, 0);
    }

    function test_pause_revertsWhenAlreadyPaused() public {
        factory.pauseMarketCreation();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.pauseMarketCreation();
    }

    function test_unpause_revertsWhenNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        factory.unpauseMarketCreation();
    }

    // ──────────────────────────────────────────────
    // updateCreationDeposit
    // ──────────────────────────────────────────────

    function test_updateCreationDeposit_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.updateCreationDeposit(20e6);
    }

    function test_updateCreationDeposit_updatesValue() public {
        factory.updateCreationDeposit(20e6);
        assertEq(factory.creationDeposit(), 20e6);
    }

    function test_updateCreationDeposit_revertsOnZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(MarketFactory.DepositBelowMinimum.selector, 0, factory.MIN_CREATION_DEPOSIT())
        );
        factory.updateCreationDeposit(0);
    }

    function test_updateCreationDeposit_revertsWhenBelowMinimum() public {
        uint256 belowMin = factory.MIN_CREATION_DEPOSIT() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(MarketFactory.DepositBelowMinimum.selector, belowMin, factory.MIN_CREATION_DEPOSIT())
        );
        factory.updateCreationDeposit(belowMin);
    }

    function test_updateCreationDeposit_succeedsAtMinimum() public {
        uint256 minDeposit = factory.MIN_CREATION_DEPOSIT();
        factory.updateCreationDeposit(minDeposit);
        assertEq(factory.creationDeposit(), minDeposit);
    }

    function test_updateCreationDeposit_affectsNewMarkets() public {
        factory.updateCreationDeposit(5e6);

        uint256 totalCost = 5e6 + INITIAL_LIQUIDITY;
        usdc.mint(alice, totalCost);

        vm.startPrank(alice);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId = factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();

        assertEq(factory.getMarket(marketId).creationDeposit, 5e6);
    }

    // ──────────────────────────────────────────────
    // updateTradingFee
    // ──────────────────────────────────────────────

    function test_updateTradingFee_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.updateTradingFee(200);
    }

    function test_updateTradingFee_updatesValue() public {
        factory.updateTradingFee(200);
        assertEq(factory.tradingFee(), 200);
    }

    function test_updateTradingFee_canSetToZero() public {
        factory.updateTradingFee(0);
        assertEq(factory.tradingFee(), 0);
    }

    function test_updateTradingFee_allowsMaxFee() public {
        factory.updateTradingFee(1000); // 10% — the max
        assertEq(factory.tradingFee(), 1000);
    }

    function test_updateTradingFee_revertsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.InvalidTradingFee.selector, 1001, 1000));
        factory.updateTradingFee(1001);
    }

    // ──────────────────────────────────────────────
    // getMarket
    // ──────────────────────────────────────────────

    function test_getMarket_returnsCorrectData() public {
        _createDefaultMarket(alice);

        IMarketFactory.MarketData memory m = factory.getMarket(0);
        assertEq(m.creator, alice);
        assertEq(m.fpmm, mockFpmm);
        assertEq(m.conditionId, MOCK_CONDITION_ID);
        assertEq(m.metadataURI, "ipfs://metadata");
        assertEq(m.creationDeposit, CREATION_DEPOSIT);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Active));
    }

    function test_getMarket_returnsEmptyForNonexistent() public view {
        IMarketFactory.MarketData memory m = factory.getMarket(999);
        assertEq(m.creator, address(0));
        assertEq(m.fpmm, address(0));
        assertEq(m.creationDeposit, 0);
    }

    // ──────────────────────────────────────────────
    // refundCreationDeposit
    // ──────────────────────────────────────────────

    function test_refundCreationDeposit_happyPath() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Resolved);

        // Fund the factory with USDC to cover the refund
        // (in createMarket the deposit stays in the factory)
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        factory.refundCreationDeposit(0);

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + CREATION_DEPOSIT);
        assertEq(factory.getMarket(0).creationDeposit, 0);
    }

    function test_refundCreationDeposit_emitsEvent() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Resolved);

        vm.expectEmit(true, true, false, true);
        emit IMarketFactory.CreationDepositRefunded(0, alice, CREATION_DEPOSIT);

        vm.prank(alice);
        factory.refundCreationDeposit(0);
    }

    function test_refundCreationDeposit_revertsIfNotResolved() public {
        _createDefaultMarket(alice);
        // Status is Active (default from createMarket)

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketNotResolvedOrCancelled.selector, 0));
        factory.refundCreationDeposit(0);
    }

    function test_refundCreationDeposit_revertsForNonCreator() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Resolved);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.NotMarketCreator.selector, 0, bob));
        factory.refundCreationDeposit(0);
    }

    function test_refundCreationDeposit_revertsOnDoubleRefund() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Resolved);

        vm.prank(alice);
        factory.refundCreationDeposit(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.DepositAlreadyRefunded.selector, 0));
        factory.refundCreationDeposit(0);
    }

    function test_refundCreationDeposit_revertsForStatusCreated() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Created);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketNotResolvedOrCancelled.selector, 0));
        factory.refundCreationDeposit(0);
    }

    function test_refundCreationDeposit_revertsForStatusResolving() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Resolving);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketNotResolvedOrCancelled.selector, 0));
        factory.refundCreationDeposit(0);
    }

    function test_refundCreationDeposit_worksForCancelledMarket() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Cancelled);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        factory.refundCreationDeposit(0);

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + CREATION_DEPOSIT);
        assertEq(factory.getMarket(0).creationDeposit, 0);
    }

    // ──────────────────────────────────────────────
    // cancelMarket (SH-T02)
    // ──────────────────────────────────────────────

    function test_cancelMarket_activeMarket() public {
        uint256 marketId = _createDefaultMarket(alice);

        vm.expectEmit(true, true, false, false);
        emit IMarketFactory.MarketCancelled(marketId, owner);

        vm.expectEmit(true, false, false, true);
        emit IMarketFactory.MarketStatusChanged(marketId, IMarketFactory.MarketStatus.Cancelled);

        factory.cancelMarket(marketId);

        assertEq(uint8(factory.getMarket(marketId).status), uint8(IMarketFactory.MarketStatus.Cancelled));
    }

    function test_cancelMarket_resolvingMarket() public {
        uint256 marketId = _createDefaultMarket(alice);
        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolving);

        factory.cancelMarket(marketId);

        assertEq(uint8(factory.getMarket(marketId).status), uint8(IMarketFactory.MarketStatus.Cancelled));
    }

    function test_cancelMarket_revertsForResolvedMarket() public {
        uint256 marketId = _createDefaultMarket(alice);
        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketFactory.InvalidStateTransition.selector,
                IMarketFactory.MarketStatus.Resolved,
                IMarketFactory.MarketStatus.Cancelled
            )
        );
        factory.cancelMarket(marketId);
    }

    function test_cancelMarket_revertsForAlreadyCancelled() public {
        uint256 marketId = _createDefaultMarket(alice);
        factory.cancelMarket(marketId);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketFactory.InvalidStateTransition.selector,
                IMarketFactory.MarketStatus.Cancelled,
                IMarketFactory.MarketStatus.Cancelled
            )
        );
        factory.cancelMarket(marketId);
    }

    function test_cancelMarket_revertsForNonOwner() public {
        uint256 marketId = _createDefaultMarket(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.cancelMarket(marketId);
    }

    function test_cancelMarket_revertsForNonexistentMarket() public {
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketDoesNotExist.selector, 999));
        factory.cancelMarket(999);
    }

    // ──────────────────────────────────────────────
    // questionId collision protection (SH-T04)
    // ──────────────────────────────────────────────

    function test_questionId_differsAcrossFactoryInstances() public {
        // Deploy a second factory with identical constructor args
        MarketFactoryHarness factory2 = new MarketFactoryHarness(
            address(usdc), conditionalTokens, fpmmFactory, CREATION_DEPOSIT, TRADING_FEE
        );
        factory2.initialize(oracleAdapter, marketResolver);

        // Mock calls for factory2 as well
        vm.mockCall(conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode());
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getConditionId.selector),
            abi.encode(MOCK_CONDITION_ID)
        );
        vm.mockCall(
            fpmmFactory,
            abi.encodeWithSelector(IFPMMDeterministicFactory.create2FixedProductMarketMaker.selector),
            abi.encode(mockFpmm)
        );

        // Create identical markets on both factories from the same sender at the same timestamp
        uint256 totalCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;

        usdc.mint(alice, totalCost * 2);
        vm.startPrank(alice);
        usdc.approve(address(factory), totalCost);
        usdc.approve(address(factory2), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 id1 = factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        uint256 id2 = factory2.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();

        // questionIds MUST differ because address(this) differs between factories
        bytes32 qid1 = factory.getMarket(id1).questionId;
        bytes32 qid2 = factory2.getMarket(id2).questionId;

        assertTrue(qid1 != bytes32(0), "questionId1 should not be zero");
        assertTrue(qid2 != bytes32(0), "questionId2 should not be zero");
        assertTrue(qid1 != qid2, "questionIds from different factory instances must differ");
    }

    function test_questionId_includesChainId() public {
        // Verify the questionId incorporates block.chainid by computing it manually
        uint256 totalCost = CREATION_DEPOSIT + INITIAL_LIQUIDITY;
        usdc.mint(alice, totalCost);

        vm.startPrank(alice);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId = factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Sports, INITIAL_LIQUIDITY, odds);
        vm.stopPrank();

        bytes32 expectedQuestionId = keccak256(abi.encodePacked(block.chainid, address(factory), uint256(0), alice, block.timestamp));
        assertEq(factory.getMarket(marketId).questionId, expectedQuestionId);
    }

    function test_cancelMarket_depositRefundAfterCancellation() public {
        uint256 marketId = _createDefaultMarket(alice);

        factory.cancelMarket(marketId);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        factory.refundCreationDeposit(marketId);

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + CREATION_DEPOSIT);
        assertEq(factory.getMarket(marketId).creationDeposit, 0);
    }
}
