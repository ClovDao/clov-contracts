// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";
import { IFPMMDeterministicFactory } from "../src/interfaces/IFPMMDeterministicFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

contract MarketFactoryFuzzTest is Test {
    MarketFactoryHarness public factory;
    MockERC20 public usdc;

    address public conditionalTokens = makeAddr("conditionalTokens");
    address public fpmmFactory = makeAddr("fpmmFactory");
    address public oracleAdapter = makeAddr("oracleAdapter");
    address public marketResolver = makeAddr("marketResolver");
    address public mockFpmm = makeAddr("mockFpmm");

    uint256 public constant CREATION_DEPOSIT = 10e6;
    uint256 public constant TRADING_FEE = 100;

    bytes32 public constant MOCK_CONDITION_ID = keccak256("mockConditionId");

    function setUp() public {
        usdc = new MockERC20();
        factory = new MarketFactoryHarness(
            address(usdc), conditionalTokens, fpmmFactory, CREATION_DEPOSIT, TRADING_FEE
        );
        factory.initialize(oracleAdapter, marketResolver);

        vm.mockCall(conditionalTokens, abi.encodeWithSelector(IConditionalTokens.prepareCondition.selector), abi.encode());
        vm.mockCall(
            conditionalTokens, abi.encodeWithSelector(IConditionalTokens.getConditionId.selector), abi.encode(MOCK_CONDITION_ID)
        );
        vm.mockCall(
            fpmmFactory,
            abi.encodeWithSelector(IFPMMDeterministicFactory.create2FixedProductMarketMaker.selector),
            abi.encode(mockFpmm)
        );
    }

    // ──────────────────────────────────────────────
    // createMarket fuzz
    // ──────────────────────────────────────────────

    function testFuzz_createMarket_alwaysIncrementsCount(uint256 initialLiquidity, uint256 hoursAhead) public {
        initialLiquidity = bound(initialLiquidity, 1, 1_000_000e6); // 1 wei to 1M USDC
        hoursAhead = bound(hoursAhead, 2, 365 * 24); // 2 hours to 1 year

        address creator = makeAddr("fuzzCreator");
        uint256 totalCost = CREATION_DEPOSIT + initialLiquidity;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 countBefore = factory.marketCount();
        factory.createMarket("ipfs://fuzz", block.timestamp + hoursAhead * 1 hours, IMarketFactory.Category.Sports, initialLiquidity, odds);
        vm.stopPrank();

        assertEq(factory.marketCount(), countBefore + 1);
    }

    function testFuzz_createMarket_creatorIsAlwaysMsgSender(address creator) public {
        vm.assume(creator != address(0));
        vm.assume(creator.code.length == 0); // EOA only (no contracts that might reject transfers)

        uint256 totalCost = CREATION_DEPOSIT + 100e6;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Sports, 100e6, odds);
        vm.stopPrank();

        assertEq(factory.getMarket(marketId).creator, creator);
    }

    function testFuzz_createMarket_storesCorrectDeposit(uint256 deposit) public {
        deposit = bound(deposit, 0, 100_000e6);

        // Update creation deposit to fuzzed value
        factory.updateCreationDeposit(deposit);

        address creator = makeAddr("fuzzCreator");
        uint256 liquidity = 100e6;
        uint256 totalCost = deposit + liquidity;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Sports, liquidity, odds);
        vm.stopPrank();

        assertEq(factory.getMarket(marketId).creationDeposit, deposit);
    }

    function testFuzz_createMarket_revertsInvalidTimestamp(uint256 timestamp) public {
        // Any timestamp <= block.timestamp + 1 hour should revert
        timestamp = bound(timestamp, 0, block.timestamp + 1 hours);

        address creator = makeAddr("fuzzCreator");
        uint256 totalCost = CREATION_DEPOSIT + 100e6;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        vm.expectRevert(MarketFactory.InvalidResolutionTimestamp.selector);
        factory.createMarket("ipfs://fuzz", timestamp, IMarketFactory.Category.Sports, 100e6, odds);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // updateTradingFee fuzz
    // ──────────────────────────────────────────────

    function testFuzz_updateTradingFee_acceptsValidFees(uint256 fee) public {
        fee = bound(fee, 0, factory.MAX_TRADING_FEE());

        factory.updateTradingFee(fee);
        assertEq(factory.tradingFee(), fee);
    }

    function testFuzz_updateTradingFee_revertsAboveMax(uint256 fee) public {
        fee = bound(fee, factory.MAX_TRADING_FEE() + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(MarketFactory.InvalidTradingFee.selector, fee, factory.MAX_TRADING_FEE()));
        factory.updateTradingFee(fee);
    }

    function testFuzz_updateTradingFee_onlyOwner(address caller) public {
        vm.assume(caller != address(this)); // not the owner

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        factory.updateTradingFee(200);
    }

    // ──────────────────────────────────────────────
    // updateCreationDeposit fuzz
    // ──────────────────────────────────────────────

    function testFuzz_updateCreationDeposit_acceptsAnyValue(uint256 deposit) public {
        factory.updateCreationDeposit(deposit);
        assertEq(factory.creationDeposit(), deposit);
    }

    function testFuzz_updateCreationDeposit_onlyOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        factory.updateCreationDeposit(20e6);
    }

    // ──────────────────────────────────────────────
    // refundCreationDeposit fuzz
    // ──────────────────────────────────────────────

    function testFuzz_refundCreationDeposit_refundsExactAmount(uint256 deposit) public {
        deposit = bound(deposit, 1, 100_000e6);
        factory.updateCreationDeposit(deposit);

        address creator = makeAddr("fuzzCreator");
        uint256 liquidity = 100e6;
        uint256 totalCost = deposit + liquidity;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Sports, liquidity, odds);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        uint256 balanceBefore = usdc.balanceOf(creator);

        vm.prank(creator);
        factory.refundCreationDeposit(marketId);

        assertEq(usdc.balanceOf(creator), balanceBefore + deposit);
        assertEq(factory.getMarket(marketId).creationDeposit, 0);
    }

    function testFuzz_refundCreationDeposit_revertsForNonCreator(address caller) public {
        address creator = makeAddr("realCreator");
        vm.assume(caller != creator);

        uint256 totalCost = CREATION_DEPOSIT + 100e6;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Sports, 100e6, odds);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus.Resolved);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.NotMarketCreator.selector, marketId, caller));
        factory.refundCreationDeposit(marketId);
    }

    function testFuzz_refundCreationDeposit_revertsForNonResolvedStatus(uint8 statusRaw) public {
        // Only statuses 0-4 are valid, exclude Resolved (3)
        statusRaw = uint8(bound(statusRaw, 0, 4));
        vm.assume(statusRaw != uint8(IMarketFactory.MarketStatus.Resolved));

        address creator = makeAddr("fuzzCreator");
        uint256 totalCost = CREATION_DEPOSIT + 100e6;
        usdc.mint(creator, totalCost);

        vm.startPrank(creator);
        usdc.approve(address(factory), totalCost);

        uint256[] memory odds = new uint256[](2);
        odds[0] = 50;
        odds[1] = 50;

        uint256 marketId =
            factory.createMarket("ipfs://fuzz", block.timestamp + 2 hours, IMarketFactory.Category.Sports, 100e6, odds);
        vm.stopPrank();

        factory.setMarketStatus(marketId, IMarketFactory.MarketStatus(statusRaw));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketNotResolved.selector, marketId));
        factory.refundCreationDeposit(marketId);
    }
}
