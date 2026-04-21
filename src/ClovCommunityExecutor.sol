// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Order, Side } from "./exchange/libraries/OrderStructs.sol";

interface ICTFExchangeMatch {
    function matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external;
}

interface IMarketFactoryCommunity {
    function isCommunityMarket(uint256 marketId) external view returns (bool);
    function accrueCreatorFee(uint256 marketId, uint256 amount) external;
}

interface INegRiskCommunityRegistry {
    function isCommunityMarket(bytes32 nrMarketId) external view returns (bool);
    function accrueCreatorFee(bytes32 nrMarketId, uint256 amount) external;
}

/// @title ClovCommunityExecutor
/// @notice Middleman between the relayer and the CTFExchange for Community-tier markets.
///         Relayers call this contract instead of the exchange directly; the contract
///         executes the match, pulls the 2.3% community taker fee in USDC from the
///         taker's proxy, and splits it three ways atomically:
///
///         • COMMUNITY_REBATE_BPS   (0.6%) → MarketRewards (maker rebate pool)
///         • COMMUNITY_CREATOR_BPS  (1.0%) → MarketFactory.accrueCreatorFee
///         • COMMUNITY_PROTOCOL_BPS (0.7%) → protocolTreasury
///
///         Curated markets do NOT pass through this contract — they go directly to the
///         exchange as before. The fee split applies only to Community markets.
///
/// @dev    Design decisions:
///         - Match is executed FIRST, then the fee is pulled. This way the taker only
///           needs to have `notional + fee` of USDC in their proxy at entry for BUY,
///           and for SELL the fee is pulled from the proceeds the exchange just credited.
///         - Only COMPLEMENTARY matches (taker opposite side to all makers) are supported
///           when the taker is SELLing. This keeps the notional computation simple and
///           covers the overwhelming majority of order flow. MINT/MERGE match types on
///           the SELL-taker path revert.
///         - Orders routed through this executor MUST have `feeRateBps = 0`. The exchange
///           should also have its per-market rate set to 0 via `setFee(marketId, 0)` at
///           market creation so the `min(orderRate, marketRate)` enforcement matches.
contract ClovCommunityExecutor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Fee split constants (in bps of notional)
    // ──────────────────────────────────────────────

    /// @notice Total taker fee charged on community market fills. 230 bps = 2.3%.
    uint256 public constant COMMUNITY_TAKER_FEE_BPS = 230;

    /// @notice Portion routed to MarketRewards as maker rebate pool funding. 60 bps = 0.6%.
    uint256 public constant COMMUNITY_REBATE_BPS = 60;

    /// @notice Portion routed to the market creator via accrueCreatorFee. 100 bps = 1.0%.
    uint256 public constant COMMUNITY_CREATOR_BPS = 100;

    /// @notice Portion routed to the protocol treasury. 70 bps = 0.7%.
    uint256 public constant COMMUNITY_PROTOCOL_BPS = 70;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ──────────────────────────────────────────────
    // Immutable / mutable external references
    // ──────────────────────────────────────────────

    IERC20 public immutable usdc;
    ICTFExchangeMatch public immutable ctfExchange;
    ICTFExchangeMatch public immutable negRiskCtfExchange;
    IMarketFactoryCommunity public immutable marketFactory;
    INegRiskCommunityRegistry public immutable negRiskRegistry;

    /// @notice Address that receives maker-rebate USDC (typically MarketRewards).
    ///         Admin-mutable so a future rewards-pool redeploy doesn't require redeploying
    ///         this executor.
    address public marketRewards;

    /// @notice Address that receives the protocol share of each community fee.
    ///         Typically a Gnosis Safe multisig.
    address public protocolTreasury;

    /// @notice Relayer EOAs authorised to invoke `matchCommunity`.
    mapping(address => bool) public operators;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event MarketRewardsUpdated(address indexed oldAddr, address indexed newAddr);
    event ProtocolTreasuryUpdated(address indexed oldAddr, address indexed newAddr);

    /// @notice Emitted once per binary community match.
    event CommunityFeeDistributed(
        uint256 indexed marketId,
        address indexed taker,
        uint256 notional,
        uint256 rebateAmount,
        uint256 creatorAmount,
        uint256 protocolAmount
    );

    /// @notice Emitted once per negRisk community match. The indexer persists both
    ///         events to the same `community_fee_distributions` table keyed by market id.
    event CommunityFeeDistributedNegRisk(
        bytes32 indexed nrMarketId,
        address indexed taker,
        uint256 notional,
        uint256 rebateAmount,
        uint256 creatorAmount,
        uint256 protocolAmount
    );

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error NotOperator(address caller);
    error NotCommunityMarket(uint256 marketId);
    error NotCommunityMarketNegRisk(bytes32 nrMarketId);
    error FeeSplitMismatch(uint256 expected, uint256 actual);
    error UnsupportedMatchType();
    error NonZeroFeeRate(uint256 orderFeeRateBps);

    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _usdc,
        address _ctfExchange,
        address _negRiskCtfExchange,
        address _marketFactory,
        address _negRiskRegistry,
        address _marketRewards,
        address _protocolTreasury
    ) Ownable(msg.sender) {
        if (
            _usdc == address(0) || _ctfExchange == address(0) || _negRiskCtfExchange == address(0)
                || _marketFactory == address(0) || _negRiskRegistry == address(0) || _marketRewards == address(0)
                || _protocolTreasury == address(0)
        ) {
            revert ZeroAddress();
        }

        // Compile-time-equivalent invariant check: the split must sum to the total fee.
        // Revert at deploy if this is ever violated so downstream math is sound.
        uint256 sum = COMMUNITY_REBATE_BPS + COMMUNITY_CREATOR_BPS + COMMUNITY_PROTOCOL_BPS;
        if (sum != COMMUNITY_TAKER_FEE_BPS) {
            revert FeeSplitMismatch(COMMUNITY_TAKER_FEE_BPS, sum);
        }

        usdc = IERC20(_usdc);
        ctfExchange = ICTFExchangeMatch(_ctfExchange);
        negRiskCtfExchange = ICTFExchangeMatch(_negRiskCtfExchange);
        marketFactory = IMarketFactoryCommunity(_marketFactory);
        negRiskRegistry = INegRiskCommunityRegistry(_negRiskRegistry);
        marketRewards = _marketRewards;
        protocolTreasury = _protocolTreasury;

        // Deployer is seeded as operator so Amoy bootstrap scripts can execute without
        // an extra addOperator step. Production deploys should addOperator(relayer) and
        // removeOperator(deployer) post-setup.
        operators[msg.sender] = true;
        emit OperatorAdded(msg.sender);
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function addOperator(address op) external onlyOwner {
        if (op == address(0)) revert ZeroAddress();
        operators[op] = true;
        emit OperatorAdded(op);
    }

    function removeOperator(address op) external onlyOwner {
        operators[op] = false;
        emit OperatorRemoved(op);
    }

    function setMarketRewards(address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        emit MarketRewardsUpdated(marketRewards, newAddr);
        marketRewards = newAddr;
    }

    function setProtocolTreasury(address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        emit ProtocolTreasuryUpdated(protocolTreasury, newAddr);
        protocolTreasury = newAddr;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ──────────────────────────────────────────────
    // Community match — binary (CTFExchange)
    // ──────────────────────────────────────────────

    /// @notice Execute a community-tier match, collect the 2.3% USDC fee from the taker,
    ///         and distribute it three-ways (rebate / creator / protocol).
    /// @dev    The taker proxy MUST have:
    ///         (a) approved this contract for USDC (at least the fee amount),
    ///         (b) approved the exchange for the trade itself (USDC for BUY, CTF shares for SELL),
    ///         (c) sufficient USDC balance to pay notional + fee (BUY) or shares for the sell (SELL).
    /// @param takerOrder       The taker order being matched.
    /// @param makerOrders      Maker orders to match against.
    /// @param takerFillAmount  Amount to fill on the taker order, in taker's makerAmount units.
    /// @param makerFillAmounts Amount to fill on each maker order, in maker's makerAmount units.
    /// @param marketId         The community market id (MarketFactory uint256).
    function matchCommunity(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts,
        uint256 marketId
    ) external whenNotPaused nonReentrant onlyOperator {
        if (!marketFactory.isCommunityMarket(marketId)) revert NotCommunityMarket(marketId);

        _validateOrders(takerOrder, makerOrders);

        // Execute the match. Exchange will settle using the proxies' existing allowances.
        ctfExchange.matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);

        uint256 notional = _computeNotional(takerOrder.side, takerFillAmount, makerFillAmounts);
        (uint256 rebateAmount, uint256 creatorAmount, uint256 protocolAmount) = _computeSplits(notional);

        // Pull total fee from taker proxy (allowance required).
        address takerProxy = takerOrder.maker;
        usdc.safeTransferFrom(takerProxy, address(this), rebateAmount + creatorAmount + protocolAmount);

        // Distribute. `accrueCreatorFee` pulls via `safeTransferFrom(msg.sender, ...)`,
        // so we must approve the factory first.
        usdc.safeTransfer(marketRewards, rebateAmount);
        usdc.forceApprove(address(marketFactory), creatorAmount);
        marketFactory.accrueCreatorFee(marketId, creatorAmount);
        usdc.safeTransfer(protocolTreasury, protocolAmount);

        emit CommunityFeeDistributed(marketId, takerProxy, notional, rebateAmount, creatorAmount, protocolAmount);
    }

    // ──────────────────────────────────────────────
    // Community match — negRisk (NegRiskCtfExchange)
    // ──────────────────────────────────────────────

    /// @notice NegRisk counterpart of {matchCommunity}. Identical flow, but keyed by
    ///         `bytes32 nrMarketId` and routed through `NegRiskCtfExchange` +
    ///         `NegRiskCommunityRegistry`.
    /// @param takerOrder       The taker order being matched.
    /// @param makerOrders      Maker orders to match against.
    /// @param takerFillAmount  Amount to fill on the taker order, in taker's makerAmount units.
    /// @param makerFillAmounts Amount to fill on each maker order, in maker's makerAmount units.
    /// @param nrMarketId       The negRisk community market id (bytes32 from
    ///                         NegRiskCommunityRegistry).
    function matchCommunityNegRisk(
        Order calldata takerOrder,
        Order[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts,
        bytes32 nrMarketId
    ) external whenNotPaused nonReentrant onlyOperator {
        if (!negRiskRegistry.isCommunityMarket(nrMarketId)) {
            revert NotCommunityMarketNegRisk(nrMarketId);
        }

        _validateOrders(takerOrder, makerOrders);

        negRiskCtfExchange.matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);

        uint256 notional = _computeNotional(takerOrder.side, takerFillAmount, makerFillAmounts);
        (uint256 rebateAmount, uint256 creatorAmount, uint256 protocolAmount) = _computeSplits(notional);

        address takerProxy = takerOrder.maker;
        usdc.safeTransferFrom(takerProxy, address(this), rebateAmount + creatorAmount + protocolAmount);

        usdc.safeTransfer(marketRewards, rebateAmount);
        usdc.forceApprove(address(negRiskRegistry), creatorAmount);
        negRiskRegistry.accrueCreatorFee(nrMarketId, creatorAmount);
        usdc.safeTransfer(protocolTreasury, protocolAmount);

        emit CommunityFeeDistributedNegRisk(
            nrMarketId, takerProxy, notional, rebateAmount, creatorAmount, protocolAmount
        );
    }

    // ──────────────────────────────────────────────
    // Internal helpers (shared between binary and negRisk paths)
    // ──────────────────────────────────────────────

    /// @dev Enforces the two cross-cutting invariants on both the taker and maker orders:
    ///        (1) feeRateBps == 0 on all orders — the exchange must NOT charge.
    ///        (2) If taker is SELL, every maker must be BUY (complementary match only).
    function _validateOrders(Order calldata takerOrder, Order[] calldata makerOrders) internal pure {
        if (takerOrder.feeRateBps != 0) revert NonZeroFeeRate(takerOrder.feeRateBps);
        for (uint256 i = 0; i < makerOrders.length; i++) {
            if (makerOrders[i].feeRateBps != 0) revert NonZeroFeeRate(makerOrders[i].feeRateBps);
        }
        if (takerOrder.side == Side.SELL) {
            for (uint256 i = 0; i < makerOrders.length; i++) {
                if (makerOrders[i].side == Side.SELL) revert UnsupportedMatchType();
            }
        }
    }

    /// @dev Notional (USDC value of the taker's fill) for fee computation.
    ///        BUY taker:  taker's makerAmount is USDC → takerFillAmount is USDC.
    ///        SELL taker: complementary makers are BUY, their makerAmount is USDC →
    ///                    sum(makerFillAmounts) is the USDC flow to the taker.
    function _computeNotional(Side takerSide, uint256 takerFillAmount, uint256[] calldata makerFillAmounts)
        internal
        pure
        returns (uint256 notional)
    {
        if (takerSide == Side.BUY) {
            notional = takerFillAmount;
        } else {
            for (uint256 i = 0; i < makerFillAmounts.length; i++) {
                notional += makerFillAmounts[i];
            }
        }
    }

    /// @dev Splits the total fee into three destinations. The protocol absorbs any
    ///      rounding dust so (rebate + creator + protocol) == totalFee exactly.
    function _computeSplits(uint256 notional)
        internal
        pure
        returns (uint256 rebateAmount, uint256 creatorAmount, uint256 protocolAmount)
    {
        uint256 totalFee = (notional * COMMUNITY_TAKER_FEE_BPS) / BPS_DENOMINATOR;
        rebateAmount = (notional * COMMUNITY_REBATE_BPS) / BPS_DENOMINATOR;
        creatorAmount = (notional * COMMUNITY_CREATOR_BPS) / BPS_DENOMINATOR;
        protocolAmount = totalFee - rebateAmount - creatorAmount;
    }
}
