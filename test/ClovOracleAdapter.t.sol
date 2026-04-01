// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { ClovOracleAdapter } from "../src/ClovOracleAdapter.sol";
import { IClovOracleAdapter } from "../src/interfaces/IClovOracleAdapter.sol";
import { IOptimisticOracleV3 } from "../src/interfaces/IOptimisticOracleV3.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IMarketResolver } from "../src/interfaces/IMarketResolver.sol";
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

/// @dev Harness that exposes internal _uint256ToString for direct testing
contract ClovOracleAdapterHarness is ClovOracleAdapter {
    constructor(
        address _umaOracle,
        address _bondToken,
        address _marketFactory,
        address _marketResolver,
        uint256 _bondAmount,
        uint64 _assertionLiveness
    )
        ClovOracleAdapter(_umaOracle, _bondToken, _marketFactory, _marketResolver, _bondAmount, _assertionLiveness)
    {}

    function exposed_uint256ToString(uint256 value) external pure returns (string memory) {
        return _uint256ToString(value);
    }
}

contract ClovOracleAdapterTest is Test {
    ClovOracleAdapterHarness public adapter;
    MockERC20 public bondToken;

    address public owner;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public umaOracle = makeAddr("umaOracle");
    address public marketFactory = makeAddr("marketFactory");
    address public marketResolver = makeAddr("marketResolver");

    uint256 public constant BOND_AMOUNT = 1000e6; // 1000 USDC
    uint64 public constant ASSERTION_LIVENESS = 7200; // 2 hours
    bytes32 public constant DEFAULT_IDENTIFIER = keccak256("ASSERT_TRUTH");
    bytes32 public constant MOCK_ASSERTION_ID = keccak256("mockAssertionId");

    function setUp() public {
        owner = address(this);
        bondToken = new MockERC20();

        // Mock UMA Oracle defaultIdentifier (called in constructor)
        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector),
            abi.encode(DEFAULT_IDENTIFIER)
        );

        adapter = new ClovOracleAdapterHarness(
            umaOracle, address(bondToken), marketFactory, marketResolver, BOND_AMOUNT, ASSERTION_LIVENESS
        );
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    /// @dev Mocks MarketFactory.getMarket to return an Active market with a past resolution timestamp
    function _mockActiveMarket(uint256 marketId) internal {
        _mockMarket(marketId, IMarketFactory.MarketStatus.Active, block.timestamp - 1);
    }

    /// @dev Mocks MarketFactory.getMarket with specific status and resolution timestamp
    function _mockMarket(uint256 marketId, IMarketFactory.MarketStatus status, uint256 resolutionTimestamp) internal {
        IMarketFactory.MarketData memory market = IMarketFactory.MarketData({
            questionId: keccak256(abi.encodePacked(marketId)),
            conditionId: keccak256(abi.encodePacked("condition", marketId)),
            fpmm: makeAddr("fpmm"),
            creator: alice,
            metadataURI: "ipfs://test",
            creationDeposit: 10e6,
            resolutionTimestamp: resolutionTimestamp,
            status: status,
            category: IMarketFactory.Category.Sports
        });

        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.getMarket.selector, marketId), abi.encode(market)
        );
    }

    /// @dev Sets up a full assertOutcome flow and returns the assertionId
    function _assertOutcome(uint256 marketId, bool outcome, address asserter)
        internal
        returns (bytes32 assertionId)
    {
        _mockActiveMarket(marketId);

        // Mint bond tokens to asserter and approve adapter
        bondToken.mint(asserter, BOND_AMOUNT);
        vm.prank(asserter);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        // Mock UMA assertTruth to return our mock assertion ID
        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector),
            abi.encode(MOCK_ASSERTION_ID)
        );

        // Mock updateMarketStatus
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode()
        );

        assertionId = adapter.assertOutcome(marketId, outcome, asserter);
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_setsStateCorrectly() public view {
        assertEq(address(adapter.umaOracle()), umaOracle);
        assertEq(address(adapter.bondToken()), address(bondToken));
        assertEq(address(adapter.marketFactory()), marketFactory);
        assertEq(address(adapter.marketResolver()), marketResolver);
        assertEq(adapter.bondAmount(), BOND_AMOUNT);
        assertEq(adapter.assertionLiveness(), ASSERTION_LIVENESS);
        assertEq(adapter.defaultIdentifier(), DEFAULT_IDENTIFIER);
        assertEq(adapter.owner(), owner);
    }

    function test_constructor_revertsOnZeroAddress_umaOracle() public {
        vm.expectRevert(ClovOracleAdapter.ZeroAddress.selector);
        new ClovOracleAdapterHarness(
            address(0), address(bondToken), marketFactory, marketResolver, BOND_AMOUNT, ASSERTION_LIVENESS
        );
    }

    function test_constructor_revertsOnZeroAddress_bondToken() public {
        // Need to mock defaultIdentifier for any valid umaOracle
        address newUma = makeAddr("newUma");
        vm.mockCall(newUma, abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector), abi.encode(DEFAULT_IDENTIFIER));

        vm.expectRevert(ClovOracleAdapter.ZeroAddress.selector);
        new ClovOracleAdapterHarness(newUma, address(0), marketFactory, marketResolver, BOND_AMOUNT, ASSERTION_LIVENESS);
    }

    function test_constructor_revertsOnZeroAddress_marketFactory() public {
        address newUma = makeAddr("newUma2");
        vm.mockCall(newUma, abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector), abi.encode(DEFAULT_IDENTIFIER));

        vm.expectRevert(ClovOracleAdapter.ZeroAddress.selector);
        new ClovOracleAdapterHarness(
            newUma, address(bondToken), address(0), marketResolver, BOND_AMOUNT, ASSERTION_LIVENESS
        );
    }

    function test_constructor_revertsOnZeroAddress_marketResolver() public {
        address newUma = makeAddr("newUma3");
        vm.mockCall(newUma, abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector), abi.encode(DEFAULT_IDENTIFIER));

        vm.expectRevert(ClovOracleAdapter.ZeroAddress.selector);
        new ClovOracleAdapterHarness(
            newUma, address(bondToken), marketFactory, address(0), BOND_AMOUNT, ASSERTION_LIVENESS
        );
    }

    // ──────────────────────────────────────────────
    // assertOutcome — Happy Path
    // ──────────────────────────────────────────────

    function test_assertOutcome_happyPath_YES() public {
        uint256 marketId = 0;
        bytes32 assertionId = _assertOutcome(marketId, true, alice);

        assertEq(assertionId, MOCK_ASSERTION_ID);

        // Verify assertion stored
        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(assertionId);
        assertEq(a.marketId, marketId);
        assertEq(a.assertionId, MOCK_ASSERTION_ID);
        assertEq(a.asserter, alice);
        assertEq(a.outcome, true);
        assertEq(a.settled, false);
        assertEq(a.resolved, false);

        // Verify marketToAssertion mapping
        assertEq(adapter.marketToAssertion(marketId), MOCK_ASSERTION_ID);
    }

    function test_assertOutcome_happyPath_NO() public {
        uint256 marketId = 1;
        bytes32 assertionId = _assertOutcome(marketId, false, bob);

        assertEq(assertionId, MOCK_ASSERTION_ID);

        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(assertionId);
        assertEq(a.outcome, false);
        assertEq(a.asserter, bob);
    }

    function test_assertOutcome_transfersBondFromAsserter() public {
        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(MOCK_ASSERTION_ID));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        uint256 aliceBefore = bondToken.balanceOf(alice);
        adapter.assertOutcome(marketId, true, alice);
        uint256 aliceAfter = bondToken.balanceOf(alice);

        assertEq(aliceBefore - aliceAfter, BOND_AMOUNT);
    }

    function test_assertOutcome_emitsOutcomeAsserted() public {
        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(MOCK_ASSERTION_ID));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.expectEmit(true, true, true, true);
        emit IClovOracleAdapter.OutcomeAsserted(marketId, MOCK_ASSERTION_ID, alice, true);

        adapter.assertOutcome(marketId, true, alice);
    }

    // ──────────────────────────────────────────────
    // assertOutcome — Reverts
    // ──────────────────────────────────────────────

    function test_assertOutcome_revertsIfMarketNotActive() public {
        uint256 marketId = 0;
        _mockMarket(marketId, IMarketFactory.MarketStatus.Resolving, block.timestamp - 1);

        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.MarketNotActive.selector, marketId));
        adapter.assertOutcome(marketId, true, alice);
    }

    function test_assertOutcome_revertsIfMarketResolved() public {
        uint256 marketId = 0;
        _mockMarket(marketId, IMarketFactory.MarketStatus.Resolved, block.timestamp - 1);

        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.MarketNotActive.selector, marketId));
        adapter.assertOutcome(marketId, true, alice);
    }

    function test_assertOutcome_revertsIfMarketCancelled() public {
        uint256 marketId = 0;
        _mockMarket(marketId, IMarketFactory.MarketStatus.Cancelled, block.timestamp - 1);

        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.MarketNotActive.selector, marketId));
        adapter.assertOutcome(marketId, true, alice);
    }

    function test_assertOutcome_revertsIfResolutionTimestampNotReached() public {
        uint256 marketId = 0;
        _mockMarket(marketId, IMarketFactory.MarketStatus.Active, block.timestamp + 1 hours);

        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.ResolutionTimestampNotReached.selector, marketId));
        adapter.assertOutcome(marketId, true, alice);
    }

    function test_assertOutcome_revertsIfMarketAlreadyAsserted() public {
        uint256 marketId = 0;
        // First assertion succeeds
        _assertOutcome(marketId, true, alice);

        // Second assertion should revert
        _mockActiveMarket(marketId);
        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.MarketAlreadyAsserted.selector, marketId));
        adapter.assertOutcome(marketId, false, bob);
    }

    function test_assertOutcome_revertsWhenPaused() public {
        adapter.pause();

        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        adapter.assertOutcome(marketId, true, alice);
    }

    function test_assertOutcome_callsUpdateMarketStatusToResolving() public {
        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(MOCK_ASSERTION_ID));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.expectCall(
            marketFactory,
            abi.encodeWithSelector(
                IMarketFactory.updateMarketStatus.selector, marketId, IMarketFactory.MarketStatus.Resolving
            )
        );

        adapter.assertOutcome(marketId, true, alice);
    }

    function test_assertOutcome_approvesBondToUmaOracle() public {
        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(MOCK_ASSERTION_ID));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        adapter.assertOutcome(marketId, true, alice);

        // After assertOutcome, adapter should have approved UMA oracle for bondAmount
        // The forceApprove + assertTruth flow means UMA took the tokens, so adapter balance should be 0
        assertEq(bondToken.balanceOf(address(adapter)), BOND_AMOUNT);
    }

    function test_assertOutcome_revertsIfZeroAddressAsserter() public {
        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        // This should revert because transferFrom with address(0) fails
        vm.expectRevert();
        adapter.assertOutcome(marketId, true, address(0));
    }

    // ──────────────────────────────────────────────
    // assertionResolvedCallback — Truth Confirmed
    // ──────────────────────────────────────────────

    function test_assertionResolvedCallback_truthConfirmed_YES() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        // Mock MarketResolver.resolve
        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());

        // Call callback as UMA Oracle
        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);

        // Verify assertion state
        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.settled, true);
        assertEq(a.resolved, true);
    }

    function test_assertionResolvedCallback_truthConfirmed_NO() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, false, alice);

        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);

        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.settled, true);
        assertEq(a.resolved, true);
    }

    function test_assertionResolvedCallback_truthConfirmed_emitsOutcomeConfirmed() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());

        vm.expectEmit(true, true, false, true);
        emit IClovOracleAdapter.OutcomeConfirmed(marketId, MOCK_ASSERTION_ID, true);

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);
    }

    function test_assertionResolvedCallback_truthConfirmed_callsResolveWithCorrectPayouts_YES() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        // Expect resolve called with payouts [1, 0] for YES
        uint256[] memory expectedPayouts = new uint256[](2);
        expectedPayouts[0] = 1;
        expectedPayouts[1] = 0;

        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());
        vm.expectCall(
            marketResolver,
            abi.encodeWithSelector(IMarketResolver.resolve.selector, marketId, expectedPayouts)
        );

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);
    }

    function test_assertionResolvedCallback_truthConfirmed_callsResolveWithCorrectPayouts_NO() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, false, alice);

        // Expect resolve called with payouts [0, 1] for NO
        uint256[] memory expectedPayouts = new uint256[](2);
        expectedPayouts[0] = 0;
        expectedPayouts[1] = 1;

        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());
        vm.expectCall(
            marketResolver,
            abi.encodeWithSelector(IMarketResolver.resolve.selector, marketId, expectedPayouts)
        );

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);
    }

    // ──────────────────────────────────────────────
    // assertionResolvedCallback — Truth Denied
    // ──────────────────────────────────────────────

    function test_assertionResolvedCallback_truthDenied_resetsToActive() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        // Mock updateMarketStatus for reset to Active
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, false);

        // Verify assertion state — settled but NOT resolved
        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.settled, true);
        assertEq(a.resolved, false);

        // Verify marketToAssertion cleared
        assertEq(adapter.marketToAssertion(marketId), bytes32(0));
    }

    function test_assertionResolvedCallback_truthDenied_callsUpdateMarketStatus() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        vm.expectCall(
            marketFactory,
            abi.encodeWithSelector(
                IMarketFactory.updateMarketStatus.selector, marketId, IMarketFactory.MarketStatus.Active
            )
        );

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, false);
    }

    // ──────────────────────────────────────────────
    // assertionResolvedCallback — Reverts
    // ──────────────────────────────────────────────

    function test_assertionResolvedCallback_revertsIfNotUmaOracle() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.prank(alice);
        vm.expectRevert(ClovOracleAdapter.OnlyUmaOracle.selector);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);
    }

    function test_assertionResolvedCallback_revertsIfAssertionNotFound() public {
        bytes32 fakeId = keccak256("doesNotExist");

        vm.prank(umaOracle);
        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.AssertionNotFound.selector, fakeId));
        adapter.assertionResolvedCallback(fakeId, true);
    }

    function test_assertionResolvedCallback_truthDenied_doesNotCallResolve() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        // We do NOT mock marketResolver.resolve — if it were called, the test would revert
        // because there's no mock for it. This implicitly verifies resolve is not called.

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, false);

        // Additionally verify resolved is false
        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.resolved, false);
    }

    function test_assertionResolvedCallback_truthDenied_emitsNoOutcomeConfirmed() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        // Record logs to verify OutcomeConfirmed is NOT emitted
        vm.recordLogs();

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 outcomeConfirmedTopic = keccak256("OutcomeConfirmed(uint256,bytes32,bool)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != outcomeConfirmedTopic, "OutcomeConfirmed should not be emitted");
        }
    }

    // ──────────────────────────────────────────────
    // assertionDisputedCallback — Happy Path
    // ──────────────────────────────────────────────

    function test_assertionDisputedCallback_resetsToActive() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);

        // Verify marketToAssertion cleared
        assertEq(adapter.marketToAssertion(marketId), bytes32(0));
    }

    function test_assertionDisputedCallback_callsUpdateMarketStatus() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        vm.expectCall(
            marketFactory,
            abi.encodeWithSelector(
                IMarketFactory.updateMarketStatus.selector, marketId, IMarketFactory.MarketStatus.Active
            )
        );

        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);
    }

    function test_assertionDisputedCallback_emitsAssertionDisputed() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.expectEmit(true, true, false, true);
        emit IClovOracleAdapter.AssertionDisputed(marketId, MOCK_ASSERTION_ID);

        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);
    }

    // ──────────────────────────────────────────────
    // assertionDisputedCallback — Reverts
    // ──────────────────────────────────────────────

    function test_assertionDisputedCallback_revertsIfNotUmaOracle() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.prank(alice);
        vm.expectRevert(ClovOracleAdapter.OnlyUmaOracle.selector);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);
    }

    function test_assertionDisputedCallback_revertsIfAssertionNotFound() public {
        bytes32 fakeId = keccak256("doesNotExist");

        vm.prank(umaOracle);
        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.AssertionNotFound.selector, fakeId));
        adapter.assertionDisputedCallback(fakeId);
    }

    // ──────────────────────────────────────────────
    // settleAndResolve
    // ──────────────────────────────────────────────

    function test_settleAndResolve_happyPath() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        // Mock settleAssertion on UMA
        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.settleAssertion.selector), abi.encode());

        adapter.settleAndResolve(marketId);
    }

    function test_settleAndResolve_callsSettleAssertionOnUma() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.settleAssertion.selector), abi.encode());
        vm.expectCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.settleAssertion.selector, MOCK_ASSERTION_ID)
        );

        adapter.settleAndResolve(marketId);
    }

    function test_settleAndResolve_revertsIfNoActiveAssertion() public {
        uint256 marketId = 99;

        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.AssertionNotFound.selector, bytes32(0)));
        adapter.settleAndResolve(marketId);
    }

    function test_settleAndResolve_revertsIfAlreadySettled() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        // Simulate UMA callback (settled = true)
        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());
        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);

        // Now settleAndResolve should revert
        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.AssertionAlreadySettled.selector, MOCK_ASSERTION_ID));
        adapter.settleAndResolve(marketId);
    }

    function test_settleAndResolve_callableByAnyone() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.settleAssertion.selector), abi.encode());

        // Bob (random user) can call settleAndResolve — no access restriction
        vm.prank(bob);
        adapter.settleAndResolve(marketId);
    }

    function test_settleAndResolve_worksWhenPaused() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        adapter.pause();

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.settleAssertion.selector), abi.encode());

        // settleAndResolve does NOT have whenNotPaused modifier, so it should work
        adapter.settleAndResolve(marketId);
    }

    function test_settleAndResolve_revertsAfterDisputeCleared() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        // Dispute clears the marketToAssertion mapping
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);

        // Now settleAndResolve should revert because marketToAssertion is cleared
        vm.expectRevert(abi.encodeWithSelector(ClovOracleAdapter.AssertionNotFound.selector, bytes32(0)));
        adapter.settleAndResolve(marketId);
    }

    // ──────────────────────────────────────────────
    // getAssertion
    // ──────────────────────────────────────────────

    function test_getAssertion_returnsStoredData() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.marketId, marketId);
        assertEq(a.assertionId, MOCK_ASSERTION_ID);
        assertEq(a.asserter, alice);
        assertEq(a.outcome, true);
        assertEq(a.settled, false);
        assertEq(a.resolved, false);
    }

    function test_getAssertion_returnsEmptyForUnknownId() public view {
        bytes32 unknownId = keccak256("unknown");
        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(unknownId);

        assertEq(a.marketId, 0);
        assertEq(a.assertionId, bytes32(0));
        assertEq(a.asserter, address(0));
        assertEq(a.outcome, false);
        assertEq(a.settled, false);
        assertEq(a.resolved, false);
    }

    // ──────────────────────────────────────────────
    // Admin — pause / unpause
    // ──────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.pause();
    }

    function test_unpause_onlyOwner() public {
        adapter.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.unpause();
    }

    function test_pause_blocksAssertOutcome() public {
        adapter.pause();

        uint256 marketId = 0;
        _mockActiveMarket(marketId);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        adapter.assertOutcome(marketId, true, alice);
    }

    function test_unpause_allowsAssertOutcome() public {
        adapter.pause();
        adapter.unpause();

        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        assertEq(adapter.marketToAssertion(marketId), MOCK_ASSERTION_ID);
    }

    // ──────────────────────────────────────────────
    // Internal — _uint256ToString
    // ──────────────────────────────────────────────

    function test_uint256ToString_zero() public view {
        assertEq(adapter.exposed_uint256ToString(0), "0");
    }

    function test_uint256ToString_singleDigit() public view {
        assertEq(adapter.exposed_uint256ToString(7), "7");
    }

    function test_uint256ToString_multiDigit() public view {
        assertEq(adapter.exposed_uint256ToString(42), "42");
        assertEq(adapter.exposed_uint256ToString(12345), "12345");
    }

    function test_uint256ToString_largeNumber() public view {
        assertEq(adapter.exposed_uint256ToString(1000000), "1000000");
    }

    // ──────────────────────────────────────────────
    // Edge Case: Dispute then re-assert
    // ──────────────────────────────────────────────

    function test_disputeThenReassert_fullCycle() public {
        uint256 marketId = 0;

        // Step 1: Initial assertion
        _assertOutcome(marketId, true, alice);
        assertEq(adapter.marketToAssertion(marketId), MOCK_ASSERTION_ID);

        // Step 2: Dispute clears the assertion
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);
        assertEq(adapter.marketToAssertion(marketId), bytes32(0));

        // Step 3: New assertion can be made
        bytes32 newAssertionId = keccak256("newAssertionId");
        _mockActiveMarket(marketId);

        bondToken.mint(bob, BOND_AMOUNT);
        vm.prank(bob);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(newAssertionId)
        );

        bytes32 returnedId = adapter.assertOutcome(marketId, false, bob);
        assertEq(returnedId, newAssertionId);
        assertEq(adapter.marketToAssertion(marketId), newAssertionId);
    }

    // ──────────────────────────────────────────────
    // Edge Case: Truth denied then re-assert
    // ──────────────────────────────────────────────

    function test_truthDeniedThenReassert_fullCycle() public {
        uint256 marketId = 0;

        // Step 1: Initial assertion
        _assertOutcome(marketId, true, alice);

        // Step 2: Resolved as NOT truthful — resets to Active
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, false);
        assertEq(adapter.marketToAssertion(marketId), bytes32(0));

        // Step 3: New assertion
        bytes32 newAssertionId = keccak256("newAssertionId2");
        _mockActiveMarket(marketId);

        bondToken.mint(bob, BOND_AMOUNT);
        vm.prank(bob);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(newAssertionId)
        );

        bytes32 returnedId = adapter.assertOutcome(marketId, false, bob);
        assertEq(returnedId, newAssertionId);
        assertEq(adapter.marketToAssertion(marketId), newAssertionId);
    }

    // ──────────────────────────────────────────────
    // Edge Case: Multiple independent markets
    // ──────────────────────────────────────────────

    function test_multipleMarkets_independentAssertions() public {
        uint256 marketId0 = 0;
        uint256 marketId1 = 1;

        bytes32 assertionId0 = keccak256("assertion0");
        bytes32 assertionId1 = keccak256("assertion1");

        // Assert market 0
        _mockActiveMarket(marketId0);
        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);
        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(assertionId0));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        adapter.assertOutcome(marketId0, true, alice);

        // Assert market 1 with different assertion ID
        _mockActiveMarket(marketId1);
        bondToken.mint(bob, BOND_AMOUNT);
        vm.prank(bob);
        bondToken.approve(address(adapter), BOND_AMOUNT);
        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(assertionId1));
        adapter.assertOutcome(marketId1, false, bob);

        // Verify independent state
        assertEq(adapter.marketToAssertion(marketId0), assertionId0);
        assertEq(adapter.marketToAssertion(marketId1), assertionId1);

        IClovOracleAdapter.Assertion memory a0 = adapter.getAssertion(assertionId0);
        assertEq(a0.marketId, marketId0);
        assertEq(a0.outcome, true);
        assertEq(a0.asserter, alice);

        IClovOracleAdapter.Assertion memory a1 = adapter.getAssertion(assertionId1);
        assertEq(a1.marketId, marketId1);
        assertEq(a1.outcome, false);
        assertEq(a1.asserter, bob);
    }

    function test_multipleMarkets_resolvingOneDoesNotAffectOther() public {
        uint256 marketId0 = 0;
        uint256 marketId1 = 1;

        bytes32 assertionId0 = keccak256("assertion0");
        bytes32 assertionId1 = keccak256("assertion1");

        // Assert both markets
        _mockActiveMarket(marketId0);
        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);
        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(assertionId0));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());
        adapter.assertOutcome(marketId0, true, alice);

        _mockActiveMarket(marketId1);
        bondToken.mint(bob, BOND_AMOUNT);
        vm.prank(bob);
        bondToken.approve(address(adapter), BOND_AMOUNT);
        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(assertionId1));
        adapter.assertOutcome(marketId1, false, bob);

        // Resolve market 0 only
        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());
        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(assertionId0, true);

        // Market 0 is resolved
        IClovOracleAdapter.Assertion memory a0 = adapter.getAssertion(assertionId0);
        assertEq(a0.settled, true);
        assertEq(a0.resolved, true);

        // Market 1 is NOT affected
        IClovOracleAdapter.Assertion memory a1 = adapter.getAssertion(assertionId1);
        assertEq(a1.settled, false);
        assertEq(a1.resolved, false);
        assertEq(adapter.marketToAssertion(marketId1), assertionId1);
    }

    // ──────────────────────────────────────────────
    // Edge Case: Callback on disputed assertion after dispute callback
    // ──────────────────────────────────────────────

    function test_assertionDisputedCallback_assertionDataPreserved() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);

        // marketToAssertion is cleared, but assertion data itself persists
        assertEq(adapter.marketToAssertion(marketId), bytes32(0));

        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.marketId, marketId);
        assertEq(a.assertionId, MOCK_ASSERTION_ID);
        assertEq(a.asserter, alice);
        assertEq(a.outcome, true);
        // Dispute callback does NOT set settled or resolved
        assertEq(a.settled, false);
        assertEq(a.resolved, false);
    }

    // ──────────────────────────────────────────────
    // Edge Case: Callbacks on already-settled assertion
    // ──────────────────────────────────────────────

    function test_assertionResolvedCallback_callableOnAlreadySettledViaDispute() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        // Dispute first
        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);

        // UMA can still call assertionResolvedCallback after dispute resolves
        // This is the normal UMA flow: dispute callback fires first, then resolved callback later
        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());

        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);

        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.settled, true);
        assertEq(a.resolved, true);
    }

    // ──────────────────────────────────────────────
    // Edge Case: UMA callbacks still work when paused
    // ──────────────────────────────────────────────

    function test_assertionResolvedCallback_worksWhenPaused() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        adapter.pause();

        vm.mockCall(marketResolver, abi.encodeWithSelector(IMarketResolver.resolve.selector), abi.encode());

        // UMA callbacks should NOT be blocked by pause — only assertOutcome is paused
        vm.prank(umaOracle);
        adapter.assertionResolvedCallback(MOCK_ASSERTION_ID, true);

        IClovOracleAdapter.Assertion memory a = adapter.getAssertion(MOCK_ASSERTION_ID);
        assertEq(a.settled, true);
        assertEq(a.resolved, true);
    }

    function test_assertionDisputedCallback_worksWhenPaused() public {
        uint256 marketId = 0;
        _assertOutcome(marketId, true, alice);

        adapter.pause();

        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        vm.prank(umaOracle);
        adapter.assertionDisputedCallback(MOCK_ASSERTION_ID);

        assertEq(adapter.marketToAssertion(marketId), bytes32(0));
    }

    // ──────────────────────────────────────────────
    // Fuzz: _uint256ToString
    // ──────────────────────────────────────────────

    function testFuzz_uint256ToString_matchesVmToString(uint256 value) public view {
        string memory result = adapter.exposed_uint256ToString(value);
        string memory expected = vm.toString(value);
        assertEq(result, expected);
    }

    // ──────────────────────────────────────────────
    // Edge Case: assertOutcome at exact resolution timestamp
    // ──────────────────────────────────────────────

    function test_assertOutcome_succeedsAtExactResolutionTimestamp() public {
        uint256 marketId = 0;
        uint256 resolutionTs = block.timestamp;
        _mockMarket(marketId, IMarketFactory.MarketStatus.Active, resolutionTs);

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(adapter), BOND_AMOUNT);

        vm.mockCall(umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(MOCK_ASSERTION_ID));
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.updateMarketStatus.selector), abi.encode());

        // block.timestamp == resolutionTimestamp should succeed (not strictly less than)
        bytes32 assertionId = adapter.assertOutcome(marketId, true, alice);
        assertEq(assertionId, MOCK_ASSERTION_ID);
    }
}
