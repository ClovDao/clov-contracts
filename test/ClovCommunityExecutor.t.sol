// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { ClovCommunityExecutor } from "../src/ClovCommunityExecutor.sol";
import { Order, Side, SignatureType } from "../src/exchange/libraries/OrderStructs.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Stub exchange whose `matchOrders` is a no-op. The Executor's job is to collect
///      the fee and distribute it — the actual settlement is tested elsewhere.
contract StubCTFExchange {
    uint256 public callCount;
    bytes public lastCalldata;

    function matchOrders(
        Order memory, /* takerOrder */
        Order[] memory, /* makerOrders */
        uint256, /* takerFillAmount */
        uint256[] memory /* makerFillAmounts */
    )
        external
    {
        callCount++;
        lastCalldata = msg.data;
    }
}

/// @dev Stub factory that mimics the real MarketFactory's accrueCreatorFee USDC pull.
contract StubMarketFactory {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    mapping(uint256 => bool) public communityMarkets;
    mapping(uint256 => uint256) public creatorFeeAccumulated;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setCommunity(uint256 marketId, bool isCommunity) external {
        communityMarkets[marketId] = isCommunity;
    }

    function isCommunityMarket(uint256 marketId) external view returns (bool) {
        return communityMarkets[marketId];
    }

    function accrueCreatorFee(uint256 marketId, uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        creatorFeeAccumulated[marketId] += amount;
    }
}

/// @dev Stub negRisk registry mirroring {StubMarketFactory} but keyed by bytes32.
contract StubNegRiskRegistry {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    mapping(bytes32 => bool) public communityMarkets;
    mapping(bytes32 => uint256) public creatorFeeAccumulated;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setCommunity(bytes32 nrMarketId, bool isCommunity) external {
        communityMarkets[nrMarketId] = isCommunity;
    }

    function isCommunityMarket(bytes32 nrMarketId) external view returns (bool) {
        return communityMarkets[nrMarketId];
    }

    function accrueCreatorFee(bytes32 nrMarketId, uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        creatorFeeAccumulated[nrMarketId] += amount;
    }
}

contract ClovCommunityExecutorTest is Test {
    ClovCommunityExecutor public executor;
    MockUSDC public usdc;
    StubCTFExchange public exchange;
    StubCTFExchange public negRiskExchange;
    StubMarketFactory public factory;
    StubNegRiskRegistry public nrRegistry;

    address public owner;
    address public relayer = makeAddr("relayer");
    address public takerProxy = makeAddr("takerProxy");
    address public makerProxy = makeAddr("makerProxy");
    address public marketRewards = makeAddr("marketRewards");
    address public protocolTreasury = makeAddr("protocolTreasury");

    uint256 public constant MARKET_ID = 42;
    bytes32 public constant NR_MARKET_ID = bytes32(uint256(0xdeadbeef));
    uint256 public constant TOKEN_ID = 999;

    function setUp() public {
        owner = address(this);
        usdc = new MockUSDC();
        exchange = new StubCTFExchange();
        negRiskExchange = new StubCTFExchange();
        factory = new StubMarketFactory(usdc);
        nrRegistry = new StubNegRiskRegistry(usdc);

        executor = new ClovCommunityExecutor(
            address(usdc),
            address(exchange),
            address(negRiskExchange),
            address(factory),
            address(nrRegistry),
            marketRewards,
            protocolTreasury
        );
        executor.addOperator(relayer);

        // Mark both market ids as community so the gates pass.
        factory.setCommunity(MARKET_ID, true);
        nrRegistry.setCommunity(NR_MARKET_ID, true);

        // Seed the taker proxy with USDC and approve the executor for unlimited.
        usdc.mint(takerProxy, 1_000_000e6);
        vm.prank(takerProxy);
        usdc.approve(address(executor), type(uint256).max);
    }

    // ──────────────────────────────────────────────
    // Fixture helpers
    // ──────────────────────────────────────────────

    function _buyTaker(uint256 makerAmount, uint256 takerAmount) internal view returns (Order memory) {
        return Order({
            salt: 1,
            maker: takerProxy,
            signer: takerProxy,
            taker: address(0),
            tokenId: TOKEN_ID,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: Side.BUY,
            signatureType: SignatureType.POLY_PROXY,
            signature: hex""
        });
    }

    function _sellTaker(uint256 makerAmount, uint256 takerAmount) internal view returns (Order memory) {
        return Order({
            salt: 2,
            maker: takerProxy,
            signer: takerProxy,
            taker: address(0),
            tokenId: TOKEN_ID,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: Side.SELL,
            signatureType: SignatureType.POLY_PROXY,
            signature: hex""
        });
    }

    function _counterMaker(Side side, uint256 makerAmount, uint256 takerAmount) internal view returns (Order memory) {
        return Order({
            salt: 100,
            maker: makerProxy,
            signer: makerProxy,
            taker: address(0),
            tokenId: TOKEN_ID,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: side,
            signatureType: SignatureType.POLY_PROXY,
            signature: hex""
        });
    }

    // ──────────────────────────────────────────────
    // Constants invariant (smoke)
    // ──────────────────────────────────────────────

    function test_constants_sum_equals_total_fee() public view {
        assertEq(
            executor.COMMUNITY_REBATE_BPS() + executor.COMMUNITY_CREATOR_BPS() + executor.COMMUNITY_PROTOCOL_BPS(),
            executor.COMMUNITY_TAKER_FEE_BPS(),
            "fee split must sum to total"
        );
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_revertsOnZeroAddress() public {
        address[7] memory args = [
            address(usdc),
            address(exchange),
            address(negRiskExchange),
            address(factory),
            address(nrRegistry),
            marketRewards,
            protocolTreasury
        ];
        for (uint256 i = 0; i < 7; i++) {
            address[7] memory mutated = args;
            mutated[i] = address(0);
            vm.expectRevert(ClovCommunityExecutor.ZeroAddress.selector);
            new ClovCommunityExecutor(
                mutated[0], mutated[1], mutated[2], mutated[3], mutated[4], mutated[5], mutated[6]
            );
        }
    }

    function test_constructor_seedsDeployerAsOperator() public view {
        assertTrue(executor.operators(owner));
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function test_addOperator_onlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        executor.addOperator(makeAddr("op"));
    }

    function test_addOperator_revertsOnZero() public {
        vm.expectRevert(ClovCommunityExecutor.ZeroAddress.selector);
        executor.addOperator(address(0));
    }

    function test_addAndRemoveOperator() public {
        address op = makeAddr("op");
        executor.addOperator(op);
        assertTrue(executor.operators(op));
        executor.removeOperator(op);
        assertFalse(executor.operators(op));
    }

    function test_setProtocolTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        executor.setProtocolTreasury(newTreasury);
        assertEq(executor.protocolTreasury(), newTreasury);
    }

    function test_setProtocolTreasury_revertsOnZero() public {
        vm.expectRevert(ClovCommunityExecutor.ZeroAddress.selector);
        executor.setProtocolTreasury(address(0));
    }

    function test_setMarketRewards() public {
        address newRewards = makeAddr("newRewards");
        executor.setMarketRewards(newRewards);
        assertEq(executor.marketRewards(), newRewards);
    }

    function test_pause_blocksMatches() public {
        executor.pause();
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        vm.prank(relayer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.matchCommunity(taker, makers, 100e6, fills, MARKET_ID);
    }

    // ──────────────────────────────────────────────
    // matchCommunity — guards
    // ──────────────────────────────────────────────

    function test_matchCommunity_revertsIfNotOperator() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NotOperator.selector, stranger));
        executor.matchCommunity(taker, makers, 0, fills, MARKET_ID);
    }

    function test_matchCommunity_revertsIfNotCommunity() public {
        uint256 curatedId = 7;
        factory.setCommunity(curatedId, false);

        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NotCommunityMarket.selector, curatedId));
        executor.matchCommunity(taker, makers, 0, fills, curatedId);
    }

    function test_matchCommunity_revertsOnTakerNonZeroFeeRate() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        taker.feeRateBps = 200;
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NonZeroFeeRate.selector, 200));
        executor.matchCommunity(taker, makers, 0, fills, MARKET_ID);
    }

    function test_matchCommunity_revertsOnMakerNonZeroFeeRate() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        makers[0].feeRateBps = 10;
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NonZeroFeeRate.selector, 10));
        executor.matchCommunity(taker, makers, 100e6, fills, MARKET_ID);
    }

    function test_matchCommunity_revertsOnSellTakerWithSellMaker() public {
        Order memory taker = _sellTaker(200e18, 100e6);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 200e18;

        vm.prank(relayer);
        vm.expectRevert(ClovCommunityExecutor.UnsupportedMatchType.selector);
        executor.matchCommunity(taker, makers, 200e18, fills, MARKET_ID);
    }

    // ──────────────────────────────────────────────
    // matchCommunity — happy path BUY
    // ──────────────────────────────────────────────

    function test_matchCommunity_buy_distributesFeeCorrectly() public {
        // Taker BUYs 200 shares @ 0.50 → notional = 100 USDC.
        // Fee expected: 2.3% × 100 = 2.30 USDC = 2_300_000 (6 dec).
        //   Rebate   (0.6%) = 600_000
        //   Creator  (1.0%) = 1_000_000
        //   Protocol (0.7%) = 700_000 (remainder)
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6; // taker fill in USDC

        uint256 takerBalBefore = usdc.balanceOf(takerProxy);
        uint256 rewardsBalBefore = usdc.balanceOf(marketRewards);
        uint256 treasuryBalBefore = usdc.balanceOf(protocolTreasury);
        uint256 factoryBalBefore = usdc.balanceOf(address(factory));

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, 100e6, fills, MARKET_ID);

        assertEq(exchange.callCount(), 1, "exchange.matchOrders must be called exactly once");
        assertEq(takerBalBefore - usdc.balanceOf(takerProxy), 2_300_000, "taker pays 2.3 USDC total fee");
        assertEq(usdc.balanceOf(marketRewards) - rewardsBalBefore, 600_000, "rewards +0.6 USDC");
        assertEq(usdc.balanceOf(address(factory)) - factoryBalBefore, 1_000_000, "factory +1.0 USDC");
        assertEq(usdc.balanceOf(protocolTreasury) - treasuryBalBefore, 700_000, "treasury +0.7 USDC");
        assertEq(factory.creatorFeeAccumulated(MARKET_ID), 1_000_000, "creatorFeeAccumulated tracked on factory");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor must not retain any USDC");
    }

    function test_matchCommunity_buy_emitsEvent() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        vm.expectEmit(true, true, false, true, address(executor));
        emit ClovCommunityExecutor.CommunityFeeDistributed(MARKET_ID, takerProxy, 100e6, 600_000, 1_000_000, 700_000);

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, 100e6, fills, MARKET_ID);
    }

    // ──────────────────────────────────────────────
    // matchCommunity — happy path SELL
    // ──────────────────────────────────────────────

    function test_matchCommunity_sell_notionalFromMakerFills() public {
        // Taker SELLs 200 shares, makers are BUY (complementary).
        // Maker offers 100 USDC for 200 shares → takerFillAmount in taker's makerAmount (shares) = 200e18.
        // Maker's makerAmount is USDC. makerFillAmounts[0] = 100e6 (USDC flowing to taker).
        // Notional = sum(makerFillAmounts) = 100 USDC.
        Order memory taker = _sellTaker(200e18, 100e6);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.BUY, 100e6, 200e18);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6; // maker fill in maker's makerAmount (USDC)

        uint256 takerBalBefore = usdc.balanceOf(takerProxy);

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, 200e18, fills, MARKET_ID);

        // Fee same as BUY case because notional is identical.
        assertEq(takerBalBefore - usdc.balanceOf(takerProxy), 2_300_000, "taker pays 2.3 USDC");
        assertEq(factory.creatorFeeAccumulated(MARKET_ID), 1_000_000, "creator gets 1 USDC");
    }

    function test_matchCommunity_sell_multipleMakersSumsNotional() public {
        Order memory taker = _sellTaker(300e18, 150e6);
        Order[] memory makers = new Order[](3);
        makers[0] = _counterMaker(Side.BUY, 50e6, 100e18);
        makers[1] = _counterMaker(Side.BUY, 60e6, 120e18);
        makers[2] = _counterMaker(Side.BUY, 40e6, 80e18);
        uint256[] memory fills = new uint256[](3);
        fills[0] = 50e6;
        fills[1] = 60e6;
        fills[2] = 40e6;
        // Total notional: 150 USDC. Fee: 2.3% × 150 = 3.45 USDC.

        uint256 takerBalBefore = usdc.balanceOf(takerProxy);

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, 300e18, fills, MARKET_ID);

        assertEq(takerBalBefore - usdc.balanceOf(takerProxy), 3_450_000, "taker pays 3.45 USDC");
        assertEq(factory.creatorFeeAccumulated(MARKET_ID), 1_500_000, "creator gets 1.5 USDC");
    }

    // ──────────────────────────────────────────────
    // Dust handling
    // ──────────────────────────────────────────────

    function test_matchCommunity_dust_absorbedByProtocol() public {
        // Notional chosen so that rebate/creator divisions leave 1 wei dust:
        // notional = 1001 (tiny). totalFee = 1001*230/10000 = 23 (int div).
        // rebateAmount = 1001*60/10000 = 6.
        // creatorAmount = 1001*100/10000 = 10.
        // protocolAmount = 23 - 6 - 10 = 7.
        // Sum: 6+10+7 = 23 = totalFee ✓. Dust absorbed by protocol.
        Order memory taker = _buyTaker(1001, 2002);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 2002, 1001);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 1001;

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, 1001, fills, MARKET_ID);

        uint256 rebate = usdc.balanceOf(marketRewards);
        uint256 creator = usdc.balanceOf(address(factory));
        uint256 protocol = usdc.balanceOf(protocolTreasury);
        assertEq(rebate, 6);
        assertEq(creator, 10);
        assertEq(protocol, 7);
        assertEq(rebate + creator + protocol, 23, "full fee distributed, zero retained in executor");
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    // ──────────────────────────────────────────────
    // matchCommunityNegRisk
    // ──────────────────────────────────────────────

    function test_matchCommunityNegRisk_revertsIfNotCommunity() public {
        bytes32 unknownId = bytes32(uint256(0x1234));
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NotCommunityMarketNegRisk.selector, unknownId));
        executor.matchCommunityNegRisk(taker, makers, 0, fills, unknownId);
    }

    function test_matchCommunityNegRisk_revertsIfNotOperator() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NotOperator.selector, stranger));
        executor.matchCommunityNegRisk(taker, makers, 0, fills, NR_MARKET_ID);
    }

    function test_matchCommunityNegRisk_buy_distributesFeeCorrectly() public {
        // Same BUY scenario as binary: notional = 100 USDC, total fee = 2.3 USDC.
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        uint256 takerBalBefore = usdc.balanceOf(takerProxy);

        vm.prank(relayer);
        executor.matchCommunityNegRisk(taker, makers, 100e6, fills, NR_MARKET_ID);

        assertEq(negRiskExchange.callCount(), 1, "negRiskExchange.matchOrders must be called");
        assertEq(exchange.callCount(), 0, "binary exchange must NOT be called");
        assertEq(takerBalBefore - usdc.balanceOf(takerProxy), 2_300_000);
        assertEq(usdc.balanceOf(marketRewards), 600_000);
        assertEq(usdc.balanceOf(address(nrRegistry)), 1_000_000);
        assertEq(usdc.balanceOf(protocolTreasury), 700_000);
        assertEq(nrRegistry.creatorFeeAccumulated(NR_MARKET_ID), 1_000_000);
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    function test_matchCommunityNegRisk_buy_emitsEvent() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        vm.expectEmit(true, true, false, true, address(executor));
        emit ClovCommunityExecutor.CommunityFeeDistributedNegRisk(
            NR_MARKET_ID, takerProxy, 100e6, 600_000, 1_000_000, 700_000
        );

        vm.prank(relayer);
        executor.matchCommunityNegRisk(taker, makers, 100e6, fills, NR_MARKET_ID);
    }

    function test_matchCommunityNegRisk_sell_notionalFromMakerFills() public {
        Order memory taker = _sellTaker(200e18, 100e6);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.BUY, 100e6, 200e18);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        vm.prank(relayer);
        executor.matchCommunityNegRisk(taker, makers, 200e18, fills, NR_MARKET_ID);

        assertEq(nrRegistry.creatorFeeAccumulated(NR_MARKET_ID), 1_000_000);
    }

    function test_matchCommunityNegRisk_revertsOnSellTakerWithSellMaker() public {
        Order memory taker = _sellTaker(200e18, 100e6);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 200e18;

        vm.prank(relayer);
        vm.expectRevert(ClovCommunityExecutor.UnsupportedMatchType.selector);
        executor.matchCommunityNegRisk(taker, makers, 200e18, fills, NR_MARKET_ID);
    }

    function test_matchCommunityNegRisk_revertsOnNonZeroFeeRate() public {
        Order memory taker = _buyTaker(100e6, 200e18);
        taker.feeRateBps = 5;
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NonZeroFeeRate.selector, 5));
        executor.matchCommunityNegRisk(taker, makers, 0, fills, NR_MARKET_ID);
    }

    function test_matchCommunityNegRisk_routesToNegRiskExchangeNotBinary() public {
        // Isolation check: calling negRisk path must NOT touch the binary factory's
        // state, and vice versa.
        Order memory taker = _buyTaker(100e6, 200e18);
        Order[] memory makers = new Order[](1);
        makers[0] = _counterMaker(Side.SELL, 200e18, 100e6);
        uint256[] memory fills = new uint256[](1);
        fills[0] = 100e6;

        vm.prank(relayer);
        executor.matchCommunityNegRisk(taker, makers, 100e6, fills, NR_MARKET_ID);

        assertEq(factory.creatorFeeAccumulated(MARKET_ID), 0, "binary factory must not accrue");
        assertEq(nrRegistry.creatorFeeAccumulated(NR_MARKET_ID), 1_000_000, "nrRegistry accrues");
    }
}
