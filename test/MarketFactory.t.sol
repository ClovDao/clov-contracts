// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";
import { IClovOracleAdapter } from "../src/interfaces/IClovOracleAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Harness that exposes internal state manipulation for testing
contract MarketFactoryHarness is MarketFactory {
    constructor(address _collateralToken, address _conditionalTokens, address _ctfExchange, uint256 _creationDeposit)
        MarketFactory(_collateralToken, _conditionalTokens, _ctfExchange, _creationDeposit)
    { }

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
    address public ctfExchange = makeAddr("ctfExchange");
    address public oracleAdapter = makeAddr("oracleAdapter");
    address public marketResolver = makeAddr("marketResolver");

    uint256 public constant CREATION_DEPOSIT = 10e6; // 10 USDC

    bytes32 public constant MOCK_CONDITION_ID = keccak256("mockConditionId");

    function setUp() public {
        owner = address(this);
        usdc = new MockERC20();

        factory = new MarketFactoryHarness(address(usdc), conditionalTokens, ctfExchange, CREATION_DEPOSIT);
        factory.initialize(oracleAdapter, marketResolver);

        // Mock ConditionalTokens.prepareCondition — just succeed
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode()
        );

        // Mock ConditionalTokens.getConditionId — return fixed conditionId
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

        // Mock exchange registerToken
        vm.mockCall(ctfExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"), abi.encode());

        // Mock ClovOracleAdapter permissionless-assertion setters — allow factory wiring
        // to succeed without a real adapter deployed.
        vm.mockCall(
            oracleAdapter, abi.encodeWithSelector(IClovOracleAdapter.setPermissionlessAssertion.selector), abi.encode()
        );
        vm.mockCall(
            oracleAdapter,
            abi.encodeWithSelector(IClovOracleAdapter.clearPermissionlessAssertion.selector),
            abi.encode()
        );
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_setsStateCorrectly() public view {
        assertEq(address(factory.collateralToken()), address(usdc));
        assertEq(address(factory.conditionalTokens()), conditionalTokens);
        assertEq(factory.oracleAdapter(), oracleAdapter);
        assertEq(factory.marketResolver(), marketResolver);
        assertEq(factory.creationDeposit(), CREATION_DEPOSIT);
        assertEq(factory.marketCount(), 0);
        assertTrue(factory.hasRole(factory.OWNER_ROLE(), owner));
        assertTrue(factory.hasRole(0x00, owner));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactoryHarness(address(0), conditionalTokens, ctfExchange, CREATION_DEPOSIT);

        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactoryHarness(address(usdc), address(0), ctfExchange, CREATION_DEPOSIT);

        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactoryHarness(address(usdc), conditionalTokens, address(0), CREATION_DEPOSIT);
    }

    function test_initialize_revertsOnZeroAddress() public {
        MarketFactoryHarness f =
            new MarketFactoryHarness(address(usdc), conditionalTokens, ctfExchange, CREATION_DEPOSIT);

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
        usdc.mint(creator, CREATION_DEPOSIT);

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        return marketId;
    }

    function test_createMarket_happyPath() public {
        uint256 marketId = _createDefaultMarket(alice);

        assertEq(marketId, 0);
        assertEq(factory.marketCount(), 1);

        IMarketFactory.MarketData memory m = factory.getMarket(0);
        assertEq(m.creator, alice);
        assertEq(m.conditionId, MOCK_CONDITION_ID);
        assertEq(m.metadataURI, "ipfs://metadata");
        assertEq(m.creationDeposit, CREATION_DEPOSIT);
        assertEq(m.resolutionTimestamp, block.timestamp + 2 hours);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Active));
        assertEq(uint8(m.category), uint8(IMarketFactory.Category.Futbol));
    }

    function test_createMarket_incrementsMarketCount() public {
        _createDefaultMarket(alice);
        _createDefaultMarket(bob);

        assertEq(factory.marketCount(), 2);
        assertEq(factory.getMarket(0).creator, alice);
        assertEq(factory.getMarket(1).creator, bob);
    }

    function test_createMarket_emitsMarketCreated() public {
        usdc.mint(alice, CREATION_DEPOSIT);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        // Check that MarketCreated is emitted (check topic1 = marketId=0 and topic2 = creator=alice)
        vm.expectEmit(true, true, false, false);
        emit IMarketFactory.MarketCreated(
            0,
            alice,
            MOCK_CONDITION_ID,
            bytes32(0),
            "ipfs://metadata",
            block.timestamp + 2 hours,
            IMarketFactory.Category.Futbol
        );

        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();
    }

    function test_createMarket_transfersTokensFromCreator() public {
        usdc.mint(alice, CREATION_DEPOSIT);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        // Alice should have 0 USDC left (deposit transferred)
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(factory)), CREATION_DEPOSIT);
    }

    function test_createMarket_revertsInvalidTimestamp() public {
        usdc.mint(alice, CREATION_DEPOSIT * 2);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT * 2);

        // Timestamp in the past
        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createMarket("ipfs://metadata", block.timestamp, IMarketFactory.Category.Futbol);

        // Timestamp exactly 1 hour from now (needs to be MORE than 1 hour)
        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 1 hours, IMarketFactory.Category.Futbol);

        vm.stopPrank();
    }

    function test_createMarket_revertsWhenPaused() public {
        factory.pauseMarketCreation();

        usdc.mint(alice, CREATION_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // pauseMarketCreation / unpauseMarketCreation
    // ──────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        bytes32 role = factory.OWNER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        factory.pauseMarketCreation();
    }

    function test_unpause_onlyOwner() public {
        factory.pauseMarketCreation();

        bytes32 role = factory.OWNER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        factory.unpauseMarketCreation();
    }

    function test_pause_blocksCreateMarket() public {
        factory.pauseMarketCreation();

        usdc.mint(alice, CREATION_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
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
        bytes32 role = factory.OWNER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
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

        usdc.mint(alice, 5e6);

        vm.startPrank(alice);
        usdc.approve(address(factory), 5e6);

        uint256 marketId =
            factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        assertEq(factory.getMarket(marketId).creationDeposit, 5e6);
    }

    // ──────────────────────────────────────────────
    // getMarket
    // ──────────────────────────────────────────────

    function test_getMarket_returnsCorrectData() public {
        _createDefaultMarket(alice);

        IMarketFactory.MarketData memory m = factory.getMarket(0);
        assertEq(m.creator, alice);
        assertEq(m.conditionId, MOCK_CONDITION_ID);
        assertEq(m.metadataURI, "ipfs://metadata");
        assertEq(m.creationDeposit, CREATION_DEPOSIT);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Active));
    }

    function test_getMarket_returnsEmptyForNonexistent() public view {
        IMarketFactory.MarketData memory m = factory.getMarket(999);
        assertEq(m.creator, address(0));
        assertEq(m.creationDeposit, 0);
    }

    // ──────────────────────────────────────────────
    // refundCreationDeposit
    // ──────────────────────────────────────────────

    function test_refundCreationDeposit_happyPath() public {
        _createDefaultMarket(alice);
        factory.setMarketStatus(0, IMarketFactory.MarketStatus.Resolved);

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
    // cancelMarket
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

        bytes32 role = factory.OWNER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        factory.cancelMarket(marketId);
    }

    function test_cancelMarket_revertsForNonexistentMarket() public {
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketDoesNotExist.selector, 999));
        factory.cancelMarket(999);
    }

    // ──────────────────────────────────────────────
    // questionId collision protection
    // ──────────────────────────────────────────────

    function test_questionId_differsAcrossFactoryInstances() public {
        // Deploy a second factory with identical constructor args
        MarketFactoryHarness factory2 =
            new MarketFactoryHarness(address(usdc), conditionalTokens, ctfExchange, CREATION_DEPOSIT);
        factory2.initialize(oracleAdapter, marketResolver);

        // Mock calls for factory2 as well
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode()
        );
        vm.mockCall(
            conditionalTokens,
            abi.encodeWithSelector(IConditionalTokens.getConditionId.selector),
            abi.encode(MOCK_CONDITION_ID)
        );

        // Create identical markets on both factories from the same sender at the same timestamp
        usdc.mint(alice, CREATION_DEPOSIT * 2);
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);
        usdc.approve(address(factory2), CREATION_DEPOSIT);

        uint256 id1 = factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        uint256 id2 =
            factory2.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
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
        usdc.mint(alice, CREATION_DEPOSIT);

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 marketId =
            factory.createMarket("ipfs://metadata", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();

        bytes32 expectedQuestionId =
            keccak256(abi.encodePacked(block.chainid, address(factory), uint256(0), alice, block.timestamp));
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

    // ──────────────────────────────────────────────
    // Community markets: createCommunityMarket
    // ──────────────────────────────────────────────

    uint256 internal constant COMMUNITY_DEPOSIT = 50e6; // default communityCreationDeposit

    function _createCommunityMarket(address creator) internal returns (uint256) {
        usdc.mint(creator, COMMUNITY_DEPOSIT);
        vm.startPrank(creator);
        usdc.approve(address(factory), COMMUNITY_DEPOSIT);
        uint256 marketId = factory.createCommunityMarket(
            "ipfs://community", block.timestamp + 2 hours, IMarketFactory.Category.Futbol
        );
        vm.stopPrank();
        return marketId;
    }

    function test_createCommunityMarket_happyPath() public {
        uint256 marketId = _createCommunityMarket(alice);

        // MarketData persisted like a Featured market, minus the business status.
        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(m.creator, alice);
        assertEq(m.metadataURI, "ipfs://community");
        assertEq(m.conditionId, MOCK_CONDITION_ID);
        assertEq(m.creationDeposit, COMMUNITY_DEPOSIT);
        assertEq(uint8(m.category), uint8(IMarketFactory.Category.Futbol));

        // Community-tier markets ship as Created (not Active) — they activate after the challenge window.
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Created));

        // Extended state reflects community tier + pending lifecycle.
        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.tier), uint8(IMarketFactory.MarketTier.Community));
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Pending));
        assertEq(ext.challengeDeadline, block.timestamp + factory.CHALLENGE_PERIOD());
        assertEq(ext.challenger, address(0));
        assertEq(ext.creatorFeeAccumulated, 0);
    }

    function test_createCommunityMarket_transfersDepositFromCreator() public {
        usdc.mint(alice, COMMUNITY_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), COMMUNITY_DEPOSIT);
        uint256 balBefore = usdc.balanceOf(alice);
        factory.createCommunityMarket("ipfs://x", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), balBefore - COMMUNITY_DEPOSIT);
        assertEq(usdc.balanceOf(address(factory)), COMMUNITY_DEPOSIT);
    }

    function test_createCommunityMarket_emitsCommunityMarketCreated() public {
        usdc.mint(alice, COMMUNITY_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), COMMUNITY_DEPOSIT);

        vm.expectEmit(true, true, false, true);
        emit IMarketFactory.CommunityMarketCreated(
            0, alice, block.timestamp + factory.CHALLENGE_PERIOD(), COMMUNITY_DEPOSIT
        );
        factory.createCommunityMarket("ipfs://x", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();
    }

    function test_createCommunityMarket_isPermissionless() public {
        // Any address (no admin role) can create a Community market.
        address randomUser = makeAddr("random");
        _createCommunityMarket(randomUser);
        assertEq(factory.getMarket(0).creator, randomUser);
    }

    function test_createCommunityMarket_revertsOnShortResolutionWindow() public {
        usdc.mint(alice, COMMUNITY_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), COMMUNITY_DEPOSIT);
        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createCommunityMarket("ipfs://x", block.timestamp + 30 minutes, IMarketFactory.Category.Futbol);
        vm.stopPrank();
    }

    function test_createCommunityMarket_revertsWhenPaused() public {
        factory.pauseMarketCreation();
        usdc.mint(alice, COMMUNITY_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(factory), COMMUNITY_DEPOSIT);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createCommunityMarket("ipfs://x", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
        vm.stopPrank();
    }

    function test_createCommunityMarket_incrementsSharedMarketCount() public {
        _createDefaultMarket(alice); // Featured → id 0
        _createCommunityMarket(bob); // Community → id 1
        assertEq(factory.marketCount(), 2);
        assertEq(factory.getMarket(0).creator, alice);
        assertEq(factory.getMarket(1).creator, bob);
    }

    function test_createMarket_featuredTier_populatesExtendedAsActive() public {
        // Featured path (existing createMarket) must also populate MarketExtended for
        // consistent reads across tiers. Tier=Featured, status=Active, no challenge data.
        uint256 marketId = _createDefaultMarket(alice);
        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.tier), uint8(IMarketFactory.MarketTier.Featured));
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Active));
        assertEq(ext.challengeDeadline, 0);
        assertEq(ext.challenger, address(0));
    }

    // ──────────────────────────────────────────────
    // challengeMarket
    // ──────────────────────────────────────────────

    bytes32 internal constant REASON = keccak256("ipfs-reason");

    function _fundAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(factory), amount);
    }

    function _fundChallenger(address who) internal {
        _fundAndApprove(who, factory.challengeBond());
    }

    function test_challengeMarket_happyPath() public {
        uint256 marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);

        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Challenged));
        assertEq(ext.challenger, bob);
        assertEq(ext.challengeBond, factory.challengeBond());
        assertEq(ext.challengeReasonHash, REASON);
    }

    function test_challengeMarket_clearsPermissionlessAssertion() public {
        uint256 marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);

        vm.expectCall(oracleAdapter, abi.encodeCall(IClovOracleAdapter.clearPermissionlessAssertion, (marketId)));
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);
    }

    function test_challengeMarket_escrowsBondInFactory() public {
        uint256 marketId = _createCommunityMarket(alice);
        uint256 bond = factory.challengeBond();
        _fundChallenger(bob);

        uint256 factoryBefore = usdc.balanceOf(address(factory));
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);

        assertEq(usdc.balanceOf(address(factory)), factoryBefore + bond);
        assertEq(usdc.balanceOf(bob), bobBefore - bond);
    }

    function test_challengeMarket_emitsMarketChallenged() public {
        uint256 marketId = _createCommunityMarket(alice);
        uint256 bond = factory.challengeBond();
        _fundChallenger(bob);

        vm.expectEmit(true, true, false, true);
        emit IMarketFactory.MarketChallenged(marketId, bob, REASON, bond);

        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);
    }

    function test_challengeMarket_revertsIfNotCommunityMarket() public {
        uint256 marketId = _createDefaultMarket(alice);
        _fundChallenger(bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, marketId));
        factory.challengeMarket(marketId, REASON);
    }

    function test_challengeMarket_revertsAfterWindowClosed() public {
        uint256 marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(bob);
        vm.expectRevert(IMarketFactory.ChallengeWindowClosed.selector);
        factory.challengeMarket(marketId, REASON);
    }

    function test_challengeMarket_revertsIfAlreadyChallenged() public {
        uint256 marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);

        address carol = makeAddr("carol");
        _fundChallenger(carol);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Challenged,
                IMarketFactory.MarketCreationStatus.Challenged
            )
        );
        factory.challengeMarket(marketId, REASON);
    }

    function test_challengeMarket_revertsOnNonexistentMarket() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, 999));
        factory.challengeMarket(999, REASON);
    }

    function test_challengeMarket_isPermissionless() public {
        uint256 marketId = _createCommunityMarket(alice);
        address anon = makeAddr("anon");
        _fundChallenger(anon);

        vm.prank(anon);
        factory.challengeMarket(marketId, REASON);

        assertEq(factory.getMarketExtended(marketId).challenger, anon);
    }

    // ──────────────────────────────────────────────
    // activateMarket
    // ──────────────────────────────────────────────

    function test_activateMarket_happyPath() public {
        uint256 marketId = _createCommunityMarket(alice);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(bob); // permissionless
        factory.activateMarket(marketId);

        // Extended lifecycle: Pending -> Active.
        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Active));

        // Business status promoted: Created -> Active (tradable).
        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Active));
    }

    function test_activateMarket_emitsMarketActivated() public {
        uint256 marketId = _createCommunityMarket(alice);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectEmit(true, false, false, false);
        emit IMarketFactory.MarketActivated(marketId);
        factory.activateMarket(marketId);
    }

    function test_activateMarket_revertsIfNotCommunity() public {
        uint256 marketId = _createDefaultMarket(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, marketId));
        factory.activateMarket(marketId);
    }

    function test_activateMarket_revertsIfWindowStillOpen() public {
        uint256 marketId = _createCommunityMarket(alice);
        vm.expectRevert(IMarketFactory.ChallengeWindowStillOpen.selector);
        factory.activateMarket(marketId);
    }

    function test_activateMarket_revertsIfChallenged() public {
        uint256 marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Challenged,
                IMarketFactory.MarketCreationStatus.Active
            )
        );
        factory.activateMarket(marketId);
    }

    function test_activateMarket_revertsIfAlreadyActive() public {
        uint256 marketId = _createCommunityMarket(alice);
        vm.warp(block.timestamp + 48 hours + 1);
        factory.activateMarket(marketId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Active,
                IMarketFactory.MarketCreationStatus.Active
            )
        );
        factory.activateMarket(marketId);
    }

    function test_activateMarket_isPermissionless() public {
        uint256 marketId = _createCommunityMarket(alice);
        vm.warp(block.timestamp + 48 hours + 1);

        address anon = makeAddr("anon2");
        vm.prank(anon);
        factory.activateMarket(marketId);

        assertEq(
            uint8(factory.getMarketExtended(marketId).creationStatus), uint8(IMarketFactory.MarketCreationStatus.Active)
        );
    }

    // ──────────────────────────────────────────────
    // accrueCreatorFee + claimCreatorFee
    // ──────────────────────────────────────────────

    address internal feeRouter = makeAddr("feeRouter");

    function _activateCommunityMarket(address creator) internal returns (uint256 marketId) {
        marketId = _createCommunityMarket(creator);
        vm.warp(block.timestamp + 48 hours + 1);
        factory.activateMarket(marketId);
    }

    function test_accrueCreatorFee_happyPath() public {
        uint256 marketId = _activateCommunityMarket(alice);
        uint256 fee = 1e6;
        _fundAndApprove(feeRouter, fee);

        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, fee);

        assertEq(factory.getMarketExtended(marketId).creatorFeeAccumulated, fee);
        assertEq(usdc.balanceOf(address(factory)), COMMUNITY_DEPOSIT + fee);
    }

    function test_accrueCreatorFee_accumulatesAcrossCalls() public {
        uint256 marketId = _activateCommunityMarket(alice);
        _fundAndApprove(feeRouter, 3e6);

        vm.startPrank(feeRouter);
        factory.accrueCreatorFee(marketId, 1e6);
        factory.accrueCreatorFee(marketId, 2e6);
        vm.stopPrank();

        assertEq(factory.getMarketExtended(marketId).creatorFeeAccumulated, 3e6);
    }

    function test_accrueCreatorFee_emitsEvent() public {
        uint256 marketId = _activateCommunityMarket(alice);
        _fundAndApprove(feeRouter, 1e6);

        vm.expectEmit(true, false, false, true);
        emit IMarketFactory.CreatorFeeAccrued(marketId, 1e6);
        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, 1e6);
    }

    function test_accrueCreatorFee_revertsIfNotCommunity() public {
        uint256 marketId = _createDefaultMarket(alice);
        _fundAndApprove(feeRouter, 1e6);

        vm.prank(feeRouter);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, marketId));
        factory.accrueCreatorFee(marketId, 1e6);
    }

    function test_accrueCreatorFee_revertsOnUnknownMarket() public {
        _fundAndApprove(feeRouter, 1e6);
        vm.prank(feeRouter);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, 42));
        factory.accrueCreatorFee(42, 1e6);
    }

    function test_claimCreatorFee_happyPath() public {
        uint256 marketId = _activateCommunityMarket(alice);
        _fundAndApprove(feeRouter, 5e6);
        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, 5e6);

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        factory.claimCreatorFee(marketId);

        assertEq(usdc.balanceOf(alice), aliceBalBefore + 5e6);
        assertEq(factory.getMarketExtended(marketId).creatorFeeAccumulated, 0);
    }

    function test_claimCreatorFee_emitsEvent() public {
        uint256 marketId = _activateCommunityMarket(alice);
        _fundAndApprove(feeRouter, 5e6);
        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, 5e6);

        vm.expectEmit(true, true, false, true);
        emit IMarketFactory.CreatorFeeClaimed(marketId, alice, 5e6);
        vm.prank(alice);
        factory.claimCreatorFee(marketId);
    }

    function test_claimCreatorFee_revertsIfNotCreator() public {
        uint256 marketId = _activateCommunityMarket(alice);
        _fundAndApprove(feeRouter, 5e6);
        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, 5e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.NotMarketCreator.selector, marketId, bob));
        factory.claimCreatorFee(marketId);
    }

    function test_claimCreatorFee_revertsIfNothingToClaim() public {
        uint256 marketId = _activateCommunityMarket(alice);

        vm.prank(alice);
        vm.expectRevert(IMarketFactory.NoCreatorFeeToClaim.selector);
        factory.claimCreatorFee(marketId);
    }

    function test_claimCreatorFee_revertsIfNotCommunity() public {
        uint256 marketId = _createDefaultMarket(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotCommunityMarket.selector, marketId));
        factory.claimCreatorFee(marketId);
    }

    // ──────────────────────────────────────────────
    // Oracle permissionless-assertion wiring
    // ──────────────────────────────────────────────

    function test_createCommunityMarket_callsSetPermissionlessAssertionOnOracle() public {
        usdc.mint(alice, COMMUNITY_DEPOSIT);
        vm.prank(alice);
        usdc.approve(address(factory), COMMUNITY_DEPOSIT);

        uint256 expectedMarketId = factory.marketCount();
        vm.expectCall(oracleAdapter, abi.encodeCall(IClovOracleAdapter.setPermissionlessAssertion, (expectedMarketId)));
        vm.prank(alice);
        factory.createCommunityMarket("ipfs://x", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
    }

    function test_createMarket_featured_doesNotCallSetPermissionless() public {
        // Featured markets stay allowlist-only. No oracle flag is set.
        usdc.mint(alice, CREATION_DEPOSIT);
        vm.prank(alice);
        usdc.approve(address(factory), CREATION_DEPOSIT);

        uint256 expectedMarketId = factory.marketCount();
        // Assert setPermissionlessAssertion is NOT called for featured-market creation.
        // The fourth arg (count = 0) makes vm.expectCall fail if the call occurs at all.
        vm.expectCall(
            oracleAdapter, abi.encodeCall(IClovOracleAdapter.setPermissionlessAssertion, (expectedMarketId)), 0
        );
        vm.prank(alice);
        factory.createMarket("ipfs://x", block.timestamp + 2 hours, IMarketFactory.Category.Futbol);
    }

    function test_challengeMarket_callsClearPermissionlessAssertion() public {
        uint256 marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);

        vm.expectCall(oracleAdapter, abi.encodeCall(IClovOracleAdapter.clearPermissionlessAssertion, (marketId)));
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);
    }

    function test_cancelMarket_communityPending_clearsPermissionlessAndMarksCancelled() public {
        uint256 marketId = _createCommunityMarket(alice);

        vm.expectCall(oracleAdapter, abi.encodeCall(IClovOracleAdapter.clearPermissionlessAssertion, (marketId)));
        factory.cancelMarket(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Cancelled));
    }

    function test_cancelMarket_featured_doesNotClearPermissionless() public {
        // Featured markets never had the flag set — cancelling must not call the clear path.
        uint256 marketId = _createDefaultMarket(alice);
        // Move through Active → Resolving to allow Cancellation via _isValidTransition.
        // Actually Active → Cancelled is a valid transition; call directly.
        factory.cancelMarket(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        // Featured extended stays Active (we don't touch it on cancel — business status moves).
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Active));
    }

    function test_claimCreatorFee_allowsSecondClaimAfterReAccrual() public {
        uint256 marketId = _activateCommunityMarket(alice);
        _fundAndApprove(feeRouter, 8e6);

        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, 3e6);
        vm.prank(alice);
        factory.claimCreatorFee(marketId);

        // Second round of fees accrues after the first claim.
        vm.prank(feeRouter);
        factory.accrueCreatorFee(marketId, 5e6);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        factory.claimCreatorFee(marketId);

        assertEq(usdc.balanceOf(alice), aliceBalBefore + 5e6);
    }

    // ──────────────────────────────────────────────
    // Layer 1 — resolveChallengeUpheld
    // ──────────────────────────────────────────────

    address internal resolver = makeAddr("resolver");
    bytes32 internal constant RESOLVE_REASON = keccak256("admin-reason");

    /// @dev Grants RESOLVER_ROLE to the test resolver. Idempotent.
    function _grantResolver() internal {
        bytes32 role = factory.RESOLVER_ROLE();
        if (!factory.hasRole(role, resolver)) {
            factory.grantRole(role, resolver);
        }
    }

    /// @dev Helper: create a community market, fund bob as challenger, and challenge it.
    function _challengedCommunityMarket() internal returns (uint256 marketId) {
        marketId = _createCommunityMarket(alice);
        _fundChallenger(bob);
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);
    }

    function test_resolveChallengeUpheld_happyPath() public {
        uint256 marketId = _challengedCommunityMarket();
        _grantResolver();

        uint256 bond = factory.challengeBond();
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(resolver);
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);

        // Challenger receives creationDeposit + chBond; creator gets nothing back.
        assertEq(usdc.balanceOf(bob), bobBefore + COMMUNITY_DEPOSIT + bond);
        assertEq(usdc.balanceOf(alice), aliceBefore);

        // Lifecycle is Cancelled, business status is Cancelled, deposit/bond zeroed.
        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Cancelled));
        assertEq(ext.challengeBond, 0);
        assertEq(ext.resolutionDeadline, block.timestamp + factory.POST_RESOLUTION_PERIOD());

        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Cancelled));
        assertEq(m.creationDeposit, 0);
    }

    function test_resolveChallengeUpheld_emitsChallengeResolved() public {
        uint256 marketId = _challengedCommunityMarket();
        _grantResolver();

        vm.expectEmit(true, true, false, true);
        emit IMarketFactory.ChallengeResolved(marketId, true, RESOLVE_REASON, bob);

        vm.prank(resolver);
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);
    }

    function test_resolveChallengeUpheld_revertsForNonResolver() public {
        uint256 marketId = _challengedCommunityMarket();
        bytes32 role = factory.RESOLVER_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);
    }

    function test_resolveChallengeUpheld_revertsIfNotChallenged_pending() public {
        uint256 marketId = _createCommunityMarket(alice);
        _grantResolver();

        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Pending,
                IMarketFactory.MarketCreationStatus.Cancelled
            )
        );
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);
    }

    function test_resolveChallengeUpheld_revertsIfAlreadyCancelled() public {
        uint256 marketId = _challengedCommunityMarket();
        _grantResolver();

        vm.prank(resolver);
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);

        // Second call reverts: state is already Cancelled.
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Cancelled,
                IMarketFactory.MarketCreationStatus.Cancelled
            )
        );
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);
    }

    // ──────────────────────────────────────────────
    // Layer 1 — resolveChallengeRejected
    // ──────────────────────────────────────────────

    function test_resolveChallengeRejected_happyPath() public {
        uint256 marketId = _challengedCommunityMarket();
        _grantResolver();

        uint256 bond = factory.challengeBond();
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(resolver);
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);

        // Creator receives chBond (bond slashed to creator).
        assertEq(usdc.balanceOf(alice), aliceBefore + bond);

        // creationDeposit stays escrowed inside the factory until refund/cancellation flow.
        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(m.creationDeposit, COMMUNITY_DEPOSIT);
        // Business status stays Created — activateMarket can promote later post-deadline.
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Created));

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Pending));
        assertEq(ext.challengeBond, 0);
        assertEq(ext.resolutionDeadline, block.timestamp + factory.POST_RESOLUTION_PERIOD());
        // Challenge deadline is `max(original, now + POST_RESOLUTION_PERIOD)`. No warp happens
        // between creation and resolution here, so the original 48h window stays larger than
        // the 24h re-arm and must be preserved.
        assertEq(ext.challengeDeadline, block.timestamp + factory.CHALLENGE_PERIOD());
    }

    function test_resolveChallengeRejected_emitsChallengeResolved() public {
        uint256 marketId = _challengedCommunityMarket();
        _grantResolver();

        vm.expectEmit(true, true, false, true);
        emit IMarketFactory.ChallengeResolved(marketId, false, RESOLVE_REASON, alice);

        vm.prank(resolver);
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);
    }

    function test_resolveChallengeRejected_revertsForNonResolver() public {
        uint256 marketId = _challengedCommunityMarket();
        bytes32 role = factory.RESOLVER_ROLE();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);
    }

    function test_resolveChallengeRejected_revertsIfNotChallenged() public {
        uint256 marketId = _createCommunityMarket(alice);
        _grantResolver();

        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Pending,
                IMarketFactory.MarketCreationStatus.Pending
            )
        );
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);
    }

    function test_resolveChallengeRejected_reArmsChallengeWindow() public {
        // Coverage of re-arm: post-rejection the market is back in Pending, so a fresh
        // challenge from a different party should succeed (intentionally deferred —
        // deeper race-condition edge case covered separately).
        uint256 marketId = _challengedCommunityMarket();
        _grantResolver();
        vm.prank(resolver);
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);

        address carol = makeAddr("carol-rearm");
        _fundChallenger(carol);
        vm.prank(carol);
        factory.challengeMarket(marketId, REASON);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Challenged));
        assertEq(ext.challenger, carol);
    }

    function test_resolveChallengeRejected_preservesOriginalDeadline_whenLargerThanReArm() public {
        // A late admin rejection must NOT shrink an originally-far-future challenge deadline.
        // Setup: market created at t0 with deadline = t0 + 48h. Challenge + rejection happen
        // ~1h later, so the naive re-arm (now + 24h ≈ t0 + 25h) is BEFORE the original t0 + 48h.
        // Expectation: deadline stays at t0 + 48h (max preserved).
        uint256 marketId = _createCommunityMarket(alice);
        IMarketFactory.MarketExtended memory pre = factory.getMarketExtended(marketId);
        uint256 originalDeadline = pre.challengeDeadline;

        _fundChallenger(bob);
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);

        // Advance only 1h — well below CHALLENGE_PERIOD (48h) and POST_RESOLUTION_PERIOD (24h)
        // so naive re-arm = now + 24h is strictly less than original t0 + 48h.
        vm.warp(block.timestamp + 1 hours);

        _grantResolver();
        vm.prank(resolver);
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);

        IMarketFactory.MarketExtended memory post = factory.getMarketExtended(marketId);
        uint256 naiveReArm = block.timestamp + factory.POST_RESOLUTION_PERIOD();
        assertGt(originalDeadline, naiveReArm, "test setup: original must exceed naive re-arm");
        assertEq(post.challengeDeadline, originalDeadline, "deadline must be preserved at the larger value");
    }

    function test_resolveChallengeRejected_extendsDeadline_whenReArmIsLarger() public {
        // Mirror case: if rejection happens late enough that now + 24h is AFTER the original
        // deadline, the re-arm should advance the deadline so a fresh challenger gets a window.
        uint256 marketId = _createCommunityMarket(alice);
        IMarketFactory.MarketExtended memory pre = factory.getMarketExtended(marketId);
        uint256 originalDeadline = pre.challengeDeadline;

        _fundChallenger(bob);
        vm.prank(bob);
        factory.challengeMarket(marketId, REASON);

        // Advance 47h — past the original 48h once we add the 24h post-resolution period.
        vm.warp(block.timestamp + 47 hours);

        _grantResolver();
        vm.prank(resolver);
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);

        IMarketFactory.MarketExtended memory post = factory.getMarketExtended(marketId);
        uint256 expected = block.timestamp + factory.POST_RESOLUTION_PERIOD();
        assertGt(expected, originalDeadline, "test setup: re-arm must exceed original");
        assertEq(post.challengeDeadline, expected, "deadline must advance to re-arm value");
    }

    // ──────────────────────────────────────────────
    // Layer 2 — escalateToUma standing + cooldown + one-shot
    // ──────────────────────────────────────────────

    /// @dev Prepares a market in the post-admin Cancelled state (admin upheld the challenge).
    function _setupPostAdminCancelled() internal returns (uint256 marketId) {
        marketId = _challengedCommunityMarket();
        _grantResolver();
        vm.prank(resolver);
        factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);
    }

    /// @dev Prepares a market in the post-admin Pending state (admin rejected the challenge).
    function _setupPostAdminPending() internal returns (uint256 marketId) {
        marketId = _challengedCommunityMarket();
        _grantResolver();
        vm.prank(resolver);
        factory.resolveChallengeRejected(marketId, RESOLVE_REASON);
    }

    /// @dev Mocks adapter.assertEscalatedChallenge so escalateToUma's external call succeeds.
    function _mockAssertEscalatedChallenge() internal {
        vm.mockCall(
            oracleAdapter,
            abi.encodeWithSelector(IClovOracleAdapter.assertEscalatedChallenge.selector),
            abi.encode(bytes32(uint256(0xA55E)))
        );
    }

    function test_escalateToUma_creatorStanding_postCancelled() public {
        uint256 marketId = _setupPostAdminCancelled();
        _mockAssertEscalatedChallenge();

        // Verifies adapter is invoked with (marketId, reasonHash, creator).
        vm.expectCall(
            oracleAdapter, abi.encodeCall(IClovOracleAdapter.assertEscalatedChallenge, (marketId, REASON, alice))
        );

        vm.expectEmit(true, true, false, false);
        emit IMarketFactory.EscalatedToUma(marketId, alice);

        vm.prank(alice);
        factory.escalateToUma(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.EscalatedToUma));
        assertTrue(ext.escalated);
        assertEq(ext.escalator, alice);
    }

    function test_escalateToUma_challengerStanding_postPending() public {
        uint256 marketId = _setupPostAdminPending();
        _mockAssertEscalatedChallenge();

        vm.expectCall(
            oracleAdapter, abi.encodeCall(IClovOracleAdapter.assertEscalatedChallenge, (marketId, REASON, bob))
        );

        vm.prank(bob);
        factory.escalateToUma(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.EscalatedToUma));
        assertEq(ext.escalator, bob);
    }

    function test_escalateToUma_revertsForRandomCaller() public {
        uint256 marketId = _setupPostAdminCancelled();
        _mockAssertEscalatedChallenge();

        address random = makeAddr("random-escalator");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotEligibleToEscalate.selector, random));
        factory.escalateToUma(marketId);
    }

    function test_escalateToUma_revertsForWinner_postCancelled() public {
        // Admin upheld the challenge → creator lost, challenger won. The winner (challenger)
        // must NOT be able to self-escalate: doing so would burn a UMA bond against an outcome
        // already decided in their favor, with no path to a different result.
        uint256 marketId = _setupPostAdminCancelled();
        _mockAssertEscalatedChallenge();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotEligibleToEscalate.selector, bob));
        factory.escalateToUma(marketId);
    }

    function test_escalateToUma_revertsForWinner_postPending() public {
        // Admin rejected the challenge → challenger lost, creator won. The winner (creator)
        // must NOT be able to self-escalate.
        uint256 marketId = _setupPostAdminPending();
        _mockAssertEscalatedChallenge();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NotEligibleToEscalate.selector, alice));
        factory.escalateToUma(marketId);
    }

    function test_escalateToUma_revertsBeforeAdminActs() public {
        // While Challenged the L1 escrow has not been disbursed — escalation must wait.
        uint256 marketId = _challengedCommunityMarket();
        _mockAssertEscalatedChallenge();

        // Creator has standing but window is closed (admin hasn't acted yet).
        vm.prank(alice);
        vm.expectRevert(IMarketFactory.EscalationWindowClosed.selector);
        factory.escalateToUma(marketId);

        // Challenger likewise blocked.
        vm.prank(bob);
        vm.expectRevert(IMarketFactory.EscalationWindowClosed.selector);
        factory.escalateToUma(marketId);
    }

    function test_escalateToUma_revertsAfterCooldownExpires() public {
        uint256 marketId = _setupPostAdminCancelled();
        _mockAssertEscalatedChallenge();

        vm.warp(block.timestamp + factory.POST_RESOLUTION_PERIOD() + 1);

        vm.prank(alice);
        vm.expectRevert(IMarketFactory.EscalationWindowClosed.selector);
        factory.escalateToUma(marketId);
    }

    function test_escalateToUma_oneShot() public {
        uint256 marketId = _setupPostAdminCancelled();
        _mockAssertEscalatedChallenge();

        vm.prank(alice);
        factory.escalateToUma(marketId);

        // Second call reverts: AlreadyEscalated guard fires before standing/state checks.
        vm.prank(bob);
        vm.expectRevert(IMarketFactory.AlreadyEscalated.selector);
        factory.escalateToUma(marketId);

        vm.prank(alice);
        vm.expectRevert(IMarketFactory.AlreadyEscalated.selector);
        factory.escalateToUma(marketId);
    }

    // ──────────────────────────────────────────────
    // Layer 2 — onEscalationUpheld / onEscalationRejected callbacks
    // ──────────────────────────────────────────────

    /// @dev Drives a market through challenge → admin decision → escalator calls escalateToUma.
    ///      Returns the marketId in EscalatedToUma state with the given escalator.
    function _setupEscalatedMarket(bool adminUpheld, bool creatorEscalates) internal returns (uint256 marketId) {
        marketId = _challengedCommunityMarket();
        _grantResolver();
        vm.prank(resolver);
        if (adminUpheld) {
            factory.resolveChallengeUpheld(marketId, RESOLVE_REASON);
        } else {
            factory.resolveChallengeRejected(marketId, RESOLVE_REASON);
        }
        _mockAssertEscalatedChallenge();

        address escalator = creatorEscalates ? alice : bob;
        vm.prank(escalator);
        factory.escalateToUma(marketId);
    }

    function test_onEscalationUpheld_revertsForNonAdapter() public {
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.OnlyOracleAdapter.selector, alice));
        factory.onEscalationUpheld(marketId);
    }

    function test_onEscalationRejected_revertsForNonAdapter() public {
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.OnlyOracleAdapter.selector, bob));
        factory.onEscalationRejected(marketId);
    }

    function test_onEscalationUpheld_challengerEscalator_marketCancelled() public {
        // Admin rejected challenge → market Pending → challenger escalates → UMA upheld
        // → market flips to Cancelled (challenger's appeal won).
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: false, creatorEscalates: false });

        vm.prank(oracleAdapter);
        factory.onEscalationUpheld(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Cancelled));

        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Cancelled));
    }

    function test_onEscalationRejected_challengerEscalator_marketStaysPending() public {
        // Admin rejected → challenger escalates → UMA rejects → admin's Pending stands.
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: false, creatorEscalates: false });

        // Mock the setPermissionlessAssertion call the callback re-issues.
        vm.expectCall(oracleAdapter, abi.encodeCall(IClovOracleAdapter.setPermissionlessAssertion, (marketId)));

        vm.prank(oracleAdapter);
        factory.onEscalationRejected(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Pending));
        // Business status untouched (still Created — activateMarket promotes post-deadline).
        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Created));
    }

    function test_onEscalationUpheld_creatorEscalator_marketReinstatedPending() public {
        // Admin upheld (cancelled) → creator escalates → UMA upheld (admin overturned)
        // → market reinstated to Pending and re-armed.
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });

        vm.expectCall(oracleAdapter, abi.encodeCall(IClovOracleAdapter.setPermissionlessAssertion, (marketId)));

        vm.prank(oracleAdapter);
        factory.onEscalationUpheld(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Pending));
        // Re-arm uses `max(original, now + POST_RESOLUTION_PERIOD)`. With no warp in setup, the
        // original creation-time deadline (CHALLENGE_PERIOD = 48h) is still larger than the
        // re-arm value (POST_RESOLUTION_PERIOD = 24h), so the original is preserved.
        assertEq(ext.challengeDeadline, block.timestamp + factory.CHALLENGE_PERIOD());
        assertGe(ext.challengeDeadline, block.timestamp + factory.POST_RESOLUTION_PERIOD());

        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Created));
    }

    function test_onEscalationUpheld_preservesOriginalDeadline_whenLargerThanReArm() public {
        // Mirror of the resolveChallengeRejected guard: `onEscalationUpheld` must not shrink an
        // originally-far-future challenge deadline when UMA reverses fast. Create at t0 with
        // deadline t0+48h; admin upheld + escalation + UMA upheld all complete within 1h of t0
        // so naive re-arm (now + 24h ≈ t0+25h) is still strictly less than the original.
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });
        IMarketFactory.MarketExtended memory pre = factory.getMarketExtended(marketId);
        uint256 originalDeadline = pre.challengeDeadline;

        vm.prank(oracleAdapter);
        factory.onEscalationUpheld(marketId);

        IMarketFactory.MarketExtended memory post = factory.getMarketExtended(marketId);
        uint256 naiveReArm = block.timestamp + factory.POST_RESOLUTION_PERIOD();
        assertGt(originalDeadline, naiveReArm, "test setup: original must exceed naive re-arm");
        assertEq(post.challengeDeadline, originalDeadline, "deadline must be preserved at the larger value");
    }

    function test_onEscalationUpheld_extendsDeadline_whenReArmIsLarger() public {
        // If UMA resolution lands AFTER the original deadline has already passed, the re-arm
        // must extend the window so the reinstated market gets a fresh challenge period.
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });
        IMarketFactory.MarketExtended memory pre = factory.getMarketExtended(marketId);
        uint256 originalDeadline = pre.challengeDeadline;

        // Warp past the original window so re-arm becomes the binding bound.
        vm.warp(originalDeadline + 1);

        vm.prank(oracleAdapter);
        factory.onEscalationUpheld(marketId);

        IMarketFactory.MarketExtended memory post = factory.getMarketExtended(marketId);
        uint256 expected = block.timestamp + factory.POST_RESOLUTION_PERIOD();
        assertGt(expected, originalDeadline, "test setup: re-arm must exceed original");
        assertEq(post.challengeDeadline, expected, "deadline must advance to re-arm value");
    }

    function test_onEscalationRejected_creatorEscalator_marketStaysCancelled() public {
        // Admin upheld (cancelled) → creator escalates → UMA rejects → admin stands → Cancelled.
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });

        vm.prank(oracleAdapter);
        factory.onEscalationRejected(marketId);

        IMarketFactory.MarketExtended memory ext = factory.getMarketExtended(marketId);
        assertEq(uint8(ext.creationStatus), uint8(IMarketFactory.MarketCreationStatus.Cancelled));

        IMarketFactory.MarketData memory m = factory.getMarket(marketId);
        assertEq(uint8(m.status), uint8(IMarketFactory.MarketStatus.Cancelled));
    }

    // ──────────────────────────────────────────────
    // Bond param setters
    // ──────────────────────────────────────────────

    function test_setChallengeBond_onlyOwner() public {
        bytes32 role = factory.OWNER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        factory.setChallengeBond(123e6);
    }

    function test_setChallengeBond_emitsAndStores() public {
        uint256 oldBond = factory.challengeBond();
        uint256 newBond = 123e6;

        vm.expectEmit(true, false, false, true);
        emit IMarketFactory.BondParamUpdated(keccak256("challengeBond"), oldBond, newBond);

        factory.setChallengeBond(newBond);
        assertEq(factory.challengeBond(), newBond);
    }

    function test_setCreationDeposit_onlyOwner() public {
        bytes32 role = factory.OWNER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        factory.setCreationDeposit(20e6);
    }

    function test_setCreationDeposit_emitsAndStores() public {
        uint256 oldDeposit = factory.creationDeposit();
        uint256 newDeposit = 25e6;

        vm.expectEmit(true, false, false, true);
        emit IMarketFactory.BondParamUpdated(keccak256("creationDeposit"), oldDeposit, newDeposit);

        factory.setCreationDeposit(newDeposit);
        assertEq(factory.creationDeposit(), newDeposit);
    }

    function test_setCommunityCreationDeposit_onlyOwner() public {
        bytes32 role = factory.OWNER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        factory.setCommunityCreationDeposit(75e6);
    }

    function test_setCommunityCreationDeposit_emitsAndStores() public {
        uint256 oldDeposit = factory.communityCreationDeposit();
        uint256 newDeposit = 75e6;

        vm.expectEmit(true, false, false, true);
        emit IMarketFactory.BondParamUpdated(keccak256("communityCreationDeposit"), oldDeposit, newDeposit);

        factory.setCommunityCreationDeposit(newDeposit);
        assertEq(factory.communityCreationDeposit(), newDeposit);
    }

    // ──────────────────────────────────────────────
    // cancelMarket guards during dispute lifecycle
    // ──────────────────────────────────────────────

    function test_cancelMarket_revertsDuringChallenged() public {
        uint256 marketId = _challengedCommunityMarket();

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.Challenged,
                IMarketFactory.MarketCreationStatus.Cancelled
            )
        );
        factory.cancelMarket(marketId);
    }

    function test_cancelMarket_revertsDuringEscalatedToUma() public {
        uint256 marketId = _setupEscalatedMarket({ adminUpheld: true, creatorEscalates: true });

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketFactory.InvalidMarketTransition.selector,
                IMarketFactory.MarketCreationStatus.EscalatedToUma,
                IMarketFactory.MarketCreationStatus.Cancelled
            )
        );
        factory.cancelMarket(marketId);
    }
}
