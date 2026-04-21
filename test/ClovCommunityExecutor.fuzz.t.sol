// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ClovCommunityExecutor } from "../src/ClovCommunityExecutor.sol";
import { Order, Side, SignatureType } from "../src/exchange/libraries/OrderStructs.sol";

// ──────────────────────────────────────────────
// Fuzz-only stub contracts (no-op exchange, USDC-pulling factory+registry)
// ──────────────────────────────────────────────

contract FuzzUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract FuzzStubExchange {
    function matchOrders(Order memory, Order[] memory, uint256, uint256[] memory) external { }
}

contract FuzzStubFactory {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    mapping(uint256 => bool) public communityMarkets;
    mapping(uint256 => uint256) public creatorFeeAccumulated;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setCommunity(uint256 id, bool v) external {
        communityMarkets[id] = v;
    }

    function isCommunityMarket(uint256 id) external view returns (bool) {
        return communityMarkets[id];
    }

    function accrueCreatorFee(uint256 id, uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        creatorFeeAccumulated[id] += amount;
    }
}

contract FuzzStubRegistry {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    mapping(bytes32 => bool) public communityMarkets;
    mapping(bytes32 => uint256) public creatorFeeAccumulated;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setCommunity(bytes32 id, bool v) external {
        communityMarkets[id] = v;
    }

    function isCommunityMarket(bytes32 id) external view returns (bool) {
        return communityMarkets[id];
    }

    function accrueCreatorFee(bytes32 id, uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        creatorFeeAccumulated[id] += amount;
    }
}

contract ClovCommunityExecutorFuzzTest is Test {
    ClovCommunityExecutor public executor;
    FuzzUSDC public usdc;
    FuzzStubExchange public exchange;
    FuzzStubExchange public negRiskExchange;
    FuzzStubFactory public factory;
    FuzzStubRegistry public registry;

    address public relayer = makeAddr("relayer");
    address public takerProxy = makeAddr("takerProxy");
    address public marketRewards = makeAddr("marketRewards");
    address public protocolTreasury = makeAddr("protocolTreasury");

    uint256 public constant BINARY_MARKET = 1;
    bytes32 public constant NR_MARKET = bytes32(uint256(0xcafe));

    // Cap fuzz notional at 1_000_000 USDC (1e12 base units) to keep USDC balances sane.
    // 1 USDC is 10^6 base units; 1M USDC is 10^12.
    uint256 public constant MAX_NOTIONAL = 1_000_000e6;

    function setUp() public {
        usdc = new FuzzUSDC();
        exchange = new FuzzStubExchange();
        negRiskExchange = new FuzzStubExchange();
        factory = new FuzzStubFactory(usdc);
        registry = new FuzzStubRegistry(usdc);

        executor = new ClovCommunityExecutor(
            address(usdc),
            address(exchange),
            address(negRiskExchange),
            address(factory),
            address(registry),
            marketRewards,
            protocolTreasury
        );
        executor.addOperator(relayer);
        factory.setCommunity(BINARY_MARKET, true);
        registry.setCommunity(NR_MARKET, true);

        // Pre-fund the taker generously; approve the executor.
        usdc.mint(takerProxy, type(uint128).max);
        vm.prank(takerProxy);
        usdc.approve(address(executor), type(uint256).max);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _buildBuyTaker(uint256 makerAmount) internal view returns (Order memory) {
        return Order({
            salt: 1,
            maker: takerProxy,
            signer: takerProxy,
            taker: address(0),
            tokenId: 999,
            makerAmount: makerAmount,
            takerAmount: makerAmount * 2,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: Side.BUY,
            signatureType: SignatureType.POLY_PROXY,
            signature: hex""
        });
    }

    function _buildSellMaker(uint256 shares, uint256 usdcAmount) internal pure returns (Order memory) {
        return Order({
            salt: 2,
            maker: address(0xB0B),
            signer: address(0xB0B),
            taker: address(0),
            tokenId: 999,
            makerAmount: shares,
            takerAmount: usdcAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: Side.SELL,
            signatureType: SignatureType.POLY_PROXY,
            signature: hex""
        });
    }

    // ──────────────────────────────────────────────
    // Invariants under fuzz input
    // ──────────────────────────────────────────────

    /// @notice For any legal notional, the three destinations sum to exactly the total
    ///         fee — the protocol absorbs rounding dust and nothing is retained in the
    ///         executor.
    function testFuzz_binary_splitSumEqualsTotalFee(uint256 notional) public {
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buildBuyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _buildSellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        uint256 balBefore = usdc.balanceOf(takerProxy);
        vm.prank(relayer);
        executor.matchCommunity(taker, makers, notional, fills, BINARY_MARKET);

        uint256 paid = balBefore - usdc.balanceOf(takerProxy);
        uint256 expectedFee = (notional * executor.COMMUNITY_TAKER_FEE_BPS()) / 10_000;
        assertEq(paid, expectedFee, "taker pays exactly totalFee");

        uint256 rebate = usdc.balanceOf(marketRewards);
        uint256 creator = usdc.balanceOf(address(factory));
        uint256 protocol = usdc.balanceOf(protocolTreasury);

        assertEq(rebate + creator + protocol, paid, "splits must sum to totalFee");
        assertEq(usdc.balanceOf(address(executor)), 0, "executor must retain 0");
    }

    /// @notice Rebate and creator amounts equal the exact bps-of-notional formula; the
    ///         protocol portion receives the remainder. This guarantees no dust leaks
    ///         to a wrong destination.
    function testFuzz_binary_splitExactPerBps(uint256 notional) public {
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buildBuyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _buildSellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, notional, fills, BINARY_MARKET);

        uint256 expectedRebate = (notional * executor.COMMUNITY_REBATE_BPS()) / 10_000;
        uint256 expectedCreator = (notional * executor.COMMUNITY_CREATOR_BPS()) / 10_000;
        uint256 expectedTotal = (notional * executor.COMMUNITY_TAKER_FEE_BPS()) / 10_000;
        uint256 expectedProtocol = expectedTotal - expectedRebate - expectedCreator;

        assertEq(usdc.balanceOf(marketRewards), expectedRebate, "rebate matches formula");
        assertEq(usdc.balanceOf(address(factory)), expectedCreator, "creator matches formula");
        assertEq(usdc.balanceOf(protocolTreasury), expectedProtocol, "protocol absorbs remainder");
    }

    /// @notice Same property on the negRisk path — independent contract, same math.
    function testFuzz_negRisk_splitSumEqualsTotalFee(uint256 notional) public {
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buildBuyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _buildSellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        uint256 balBefore = usdc.balanceOf(takerProxy);
        vm.prank(relayer);
        executor.matchCommunityNegRisk(taker, makers, notional, fills, NR_MARKET);

        uint256 paid = balBefore - usdc.balanceOf(takerProxy);
        uint256 expectedFee = (notional * executor.COMMUNITY_TAKER_FEE_BPS()) / 10_000;
        assertEq(paid, expectedFee);

        uint256 rebate = usdc.balanceOf(marketRewards);
        uint256 creator = usdc.balanceOf(address(registry));
        uint256 protocol = usdc.balanceOf(protocolTreasury);

        assertEq(rebate + creator + protocol, paid);
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    /// @notice Verifies that a random non-community marketId always reverts, regardless
    ///         of other input.
    function testFuzz_binary_revertsOnUnknownMarket(uint256 marketId, uint256 notional) public {
        vm.assume(marketId != BINARY_MARKET);
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buildBuyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _buildSellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NotCommunityMarket.selector, marketId));
        executor.matchCommunity(taker, makers, notional, fills, marketId);
    }

    function testFuzz_negRisk_revertsOnUnknownMarket(bytes32 nrMarketId, uint256 notional) public {
        vm.assume(nrMarketId != NR_MARKET);
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buildBuyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _buildSellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NotCommunityMarketNegRisk.selector, nrMarketId));
        executor.matchCommunityNegRisk(taker, makers, notional, fills, nrMarketId);
    }

    /// @notice Any non-zero feeRateBps on the taker reverts regardless of value.
    function testFuzz_revertsOnTakerNonZeroFeeRate(uint256 feeRateBps) public {
        vm.assume(feeRateBps != 0 && feeRateBps <= 10_000);

        Order memory taker = _buildBuyTaker(100e6);
        taker.feeRateBps = feeRateBps;
        Order[] memory makers = new Order[](0);
        uint256[] memory fills = new uint256[](0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ClovCommunityExecutor.NonZeroFeeRate.selector, feeRateBps));
        executor.matchCommunity(taker, makers, 0, fills, BINARY_MARKET);
    }
}
