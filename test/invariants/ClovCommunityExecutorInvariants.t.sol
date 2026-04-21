// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ClovCommunityExecutor } from "../../src/ClovCommunityExecutor.sol";
import { Order, Side, SignatureType } from "../../src/exchange/libraries/OrderStructs.sol";

// ──────────────────────────────────────────────
// Stubs
// ──────────────────────────────────────────────

contract InvUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract InvStubExchange {
    function matchOrders(Order memory, Order[] memory, uint256, uint256[] memory) external { }
}

contract InvStubFactory {
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

contract InvStubRegistry {
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

// ──────────────────────────────────────────────
// Handler
// ──────────────────────────────────────────────

/// @dev Fuzz handler. Each invariant run executes a sequence of (binary/negRisk) matches
///      from a pool of pre-configured markets with bounded notionals. Tracks ghost
///      totals so the invariants can cross-check on-chain state.
contract ExecutorHandler is Test {
    ClovCommunityExecutor public executor;
    InvUSDC public usdc;
    InvStubFactory public factory;
    InvStubRegistry public registry;
    address public relayer;
    address public takerProxy;
    address public marketRewards;
    address public protocolTreasury;

    uint256 public constant MARKETS = 5;
    uint256 public constant MAX_NOTIONAL = 100_000e6; // 100k USDC per match

    uint256[MARKETS] public binaryIds;
    bytes32[MARKETS] public negRiskIds;

    // Ghost totals (indexed by market slot)
    mapping(uint256 => uint256) public ghost_binaryCreator;
    mapping(bytes32 => uint256) public ghost_negRiskCreator;
    uint256 public ghost_totalRebate;
    uint256 public ghost_totalProtocol;
    uint256 public ghost_matchCount;

    constructor(
        ClovCommunityExecutor _executor,
        InvUSDC _usdc,
        InvStubFactory _factory,
        InvStubRegistry _registry,
        address _relayer,
        address _takerProxy,
        address _marketRewards,
        address _protocolTreasury
    ) {
        executor = _executor;
        usdc = _usdc;
        factory = _factory;
        registry = _registry;
        relayer = _relayer;
        takerProxy = _takerProxy;
        marketRewards = _marketRewards;
        protocolTreasury = _protocolTreasury;

        for (uint256 i = 0; i < MARKETS; i++) {
            binaryIds[i] = 1000 + i;
            negRiskIds[i] = keccak256(abi.encodePacked("inv-nr-market", i));
            factory.setCommunity(binaryIds[i], true);
            registry.setCommunity(negRiskIds[i], true);
        }
    }

    function handlerMatchBinary(uint256 marketSeed, uint256 notional) external {
        uint256 idx = marketSeed % MARKETS;
        uint256 marketId = binaryIds[idx];
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _sellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        uint256 creator = (notional * executor.COMMUNITY_CREATOR_BPS()) / 10_000;
        uint256 rebate = (notional * executor.COMMUNITY_REBATE_BPS()) / 10_000;
        uint256 total = (notional * executor.COMMUNITY_TAKER_FEE_BPS()) / 10_000;
        uint256 protocol = total - creator - rebate;

        ghost_binaryCreator[marketId] += creator;
        ghost_totalRebate += rebate;
        ghost_totalProtocol += protocol;
        ghost_matchCount += 1;

        vm.prank(relayer);
        executor.matchCommunity(taker, makers, notional, fills, marketId);
    }

    function handlerMatchNegRisk(uint256 marketSeed, uint256 notional) external {
        uint256 idx = marketSeed % MARKETS;
        bytes32 marketId = negRiskIds[idx];
        notional = bound(notional, 1, MAX_NOTIONAL);

        Order memory taker = _buyTaker(notional);
        Order[] memory makers = new Order[](1);
        makers[0] = _sellMaker(notional * 2, notional);
        uint256[] memory fills = new uint256[](1);
        fills[0] = notional;

        uint256 creator = (notional * executor.COMMUNITY_CREATOR_BPS()) / 10_000;
        uint256 rebate = (notional * executor.COMMUNITY_REBATE_BPS()) / 10_000;
        uint256 total = (notional * executor.COMMUNITY_TAKER_FEE_BPS()) / 10_000;
        uint256 protocol = total - creator - rebate;

        ghost_negRiskCreator[marketId] += creator;
        ghost_totalRebate += rebate;
        ghost_totalProtocol += protocol;
        ghost_matchCount += 1;

        vm.prank(relayer);
        executor.matchCommunityNegRisk(taker, makers, notional, fills, marketId);
    }

    function _buyTaker(uint256 makerAmount) internal view returns (Order memory) {
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

    function _sellMaker(uint256 shares, uint256 usdcAmount) internal pure returns (Order memory) {
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
}

// ──────────────────────────────────────────────
// Invariant test harness
// ──────────────────────────────────────────────

contract ClovCommunityExecutorInvariantsTest is StdInvariant, Test {
    ClovCommunityExecutor public executor;
    InvUSDC public usdc;
    InvStubExchange public binaryExchange;
    InvStubExchange public negRiskExchange;
    InvStubFactory public factory;
    InvStubRegistry public registry;
    ExecutorHandler public handler;

    address public relayer = makeAddr("relayer");
    address public takerProxy = makeAddr("takerProxy");
    address public marketRewards = makeAddr("marketRewards");
    address public protocolTreasury = makeAddr("protocolTreasury");

    function setUp() public {
        usdc = new InvUSDC();
        binaryExchange = new InvStubExchange();
        negRiskExchange = new InvStubExchange();
        factory = new InvStubFactory(usdc);
        registry = new InvStubRegistry(usdc);

        executor = new ClovCommunityExecutor(
            address(usdc),
            address(binaryExchange),
            address(negRiskExchange),
            address(factory),
            address(registry),
            marketRewards,
            protocolTreasury
        );
        executor.addOperator(relayer);

        usdc.mint(takerProxy, type(uint128).max);
        vm.prank(takerProxy);
        usdc.approve(address(executor), type(uint256).max);

        handler = new ExecutorHandler(
            executor, usdc, factory, registry, relayer, takerProxy, marketRewards, protocolTreasury
        );
        targetContract(address(handler));
    }

    // ──────────────────────────────────────────────
    // Invariants
    // ──────────────────────────────────────────────

    /// @notice The executor never retains USDC. All fees collected are fully distributed
    ///         in the same tx.
    function invariant_executorHoldsZeroUsdc() public view {
        assertEq(usdc.balanceOf(address(executor)), 0, "executor must not retain USDC");
    }

    /// @notice MarketRewards balance equals ghost total rebate across all matches.
    function invariant_marketRewardsEqualsTotalRebate() public view {
        assertEq(usdc.balanceOf(marketRewards), handler.ghost_totalRebate(), "rewards pool matches ghost total");
    }

    /// @notice Protocol treasury balance equals ghost total protocol amount.
    function invariant_treasuryEqualsTotalProtocol() public view {
        assertEq(usdc.balanceOf(protocolTreasury), handler.ghost_totalProtocol(), "treasury matches ghost total");
    }

    /// @notice For each binary market, on-chain creatorFeeAccumulated matches the ghost.
    ///         Iterates only the handler's known market ids.
    function invariant_binaryCreatorAccumulatorMatchesGhost() public view {
        for (uint256 i = 0; i < handler.MARKETS(); i++) {
            uint256 marketId = handler.binaryIds(i);
            assertEq(
                factory.creatorFeeAccumulated(marketId),
                handler.ghost_binaryCreator(marketId),
                "binary creator accumulator matches ghost"
            );
        }
    }

    /// @notice Same for negRisk.
    function invariant_negRiskCreatorAccumulatorMatchesGhost() public view {
        for (uint256 i = 0; i < handler.MARKETS(); i++) {
            bytes32 marketId = handler.negRiskIds(i);
            assertEq(
                registry.creatorFeeAccumulated(marketId),
                handler.ghost_negRiskCreator(marketId),
                "negRisk creator accumulator matches ghost"
            );
        }
    }

    /// @notice Global conservation: sum of all creator accumulators + rewards balance +
    ///         treasury balance equals the total USDC pulled from the taker proxy.
    function invariant_globalConservation() public view {
        uint256 totalCreator;
        for (uint256 i = 0; i < handler.MARKETS(); i++) {
            totalCreator += factory.creatorFeeAccumulated(handler.binaryIds(i));
            totalCreator += registry.creatorFeeAccumulated(handler.negRiskIds(i));
        }
        uint256 distributed = totalCreator + usdc.balanceOf(marketRewards) + usdc.balanceOf(protocolTreasury);
        uint256 pulled = type(uint128).max - usdc.balanceOf(takerProxy);
        assertEq(distributed, pulled, "every unit the taker paid is accounted for in a destination");
    }
}
