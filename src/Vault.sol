// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { IConditionalTokens } from "./interfaces/IConditionalTokens.sol";
import { IFPMM } from "./interfaces/IFPMM.sol";

/// @title Vault
/// @notice Custodial vault for USDC deposits and ConditionalTokens positions in Clov prediction markets
/// @dev Enables deposit-once, trade-without-friction UX. Users deposit USDC, and the Vault
///      holds both collateral and ERC1155 outcome tokens on their behalf.
///      Trading is proxied through FPMM contracts (buyPosition / sellPosition).
contract Vault is Ownable, Pausable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientPositionBalance(uint256 requested, uint256 available);
    error InvalidOutcomeIndex(uint256 outcomeIndex);
    error MarketCollateralMismatch(address expected, address actual);
    error MarketConditionalTokensMismatch(address expected, address actual);
    error NoTokensReceived();
    error NoCollateralReceived();
    error RescueDenied();
    error NoPositionsToRedeem();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event PositionBought(
        address indexed user,
        address indexed market,
        uint256 outcomeIndex,
        uint256 investmentAmount,
        uint256 outcomeTokensBought
    );
    event PositionSold(
        address indexed user,
        address indexed market,
        uint256 outcomeIndex,
        uint256 returnAmount,
        uint256 outcomeTokensSold
    );
    event PositionRedeemed(address indexed user, address indexed market, uint256 collateralReceived);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────
    // Immutable / External Contracts
    // ──────────────────────────────────────────────

    /// @notice USDC token used as collateral
    IERC20 public immutable collateralToken;

    /// @notice Gnosis ConditionalTokens contract (ERC1155 outcome tokens)
    IConditionalTokens public immutable conditionalTokens;

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    /// @notice USDC balance per user
    mapping(address => uint256) public balances;

    /// @notice Outcome token positions per user: user => positionId => amount
    mapping(address => mapping(bytes32 => uint256)) public positions;

    /// @notice Stored redemption rate per position: positionId => collateral per token (scaled by 1e18)
    mapping(bytes32 => uint256) public redemptionRates;

    /// @notice Whether a position has already been redeemed at the vault level
    mapping(bytes32 => bool) public positionRedeemed;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    /// @param _collateralToken Address of the USDC token contract
    /// @param _conditionalTokens Address of the Gnosis ConditionalTokens contract
    constructor(address _collateralToken, address _conditionalTokens) Ownable(msg.sender) {
        if (_collateralToken == address(0) || _conditionalTokens == address(0)) {
            revert ZeroAddress();
        }

        collateralToken = IERC20(_collateralToken);
        conditionalTokens = IConditionalTokens(_conditionalTokens);
    }

    // ──────────────────────────────────────────────
    // Deposit / Withdraw
    // ──────────────────────────────────────────────

    /// @notice Deposit USDC into the Vault
    /// @dev Transfers USDC from caller to this contract and credits internal balance.
    ///      Requires prior ERC20 approval.
    /// @param amount Amount of USDC to deposit (6 decimals)
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // CEI: update state before external call
        balances[msg.sender] += amount;

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw USDC from the Vault
    /// @dev Debits internal balance and transfers USDC to caller
    /// @param amount Amount of USDC to withdraw (6 decimals)
    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 currentBalance = balances[msg.sender];
        if (amount > currentBalance) {
            revert InsufficientBalance(amount, currentBalance);
        }

        // CEI: update state before external call
        balances[msg.sender] = currentBalance - amount;

        collateralToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    // Trading Proxy
    // ──────────────────────────────────────────────

    /// @notice Buy outcome tokens on behalf of user via FPMM
    /// @dev Debits user USDC balance, approves and calls FPMM.buy(), credits outcome tokens.
    ///      Uses before/after ERC1155 balance snapshots for exact accounting.
    /// @param market Address of the FPMM market contract
    /// @param outcomeIndex 0 for Yes, 1 for No
    /// @param amount USDC amount to spend from vault balance
    /// @param minOutcomeTokens Minimum outcome tokens to receive (slippage protection)
    function buyPosition(
        address market,
        uint256 outcomeIndex,
        uint256 amount,
        uint256 minOutcomeTokens
    ) external whenNotPaused nonReentrant {
        if (market == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (outcomeIndex > 1) revert InvalidOutcomeIndex(outcomeIndex);

        // Validate FPMM uses same collateral and ConditionalTokens
        _validateMarket(market);

        // Debit user USDC balance (CEI: state change before external calls)
        uint256 currentBalance = balances[msg.sender];
        if (amount > currentBalance) {
            revert InsufficientBalance(amount, currentBalance);
        }
        balances[msg.sender] = currentBalance - amount;

        // Compute positionId for this outcome
        bytes32 positionId = _getPositionId(market, outcomeIndex);

        // Snapshot ERC1155 balance before trade
        uint256 tokenBalanceBefore = conditionalTokens.balanceOf(address(this), uint256(positionId));

        // Approve USDC to FPMM and execute buy
        collateralToken.forceApprove(market, amount);
        IFPMM(market).buy(amount, outcomeIndex, minOutcomeTokens);

        // Snapshot ERC1155 balance after trade and compute tokens received
        uint256 tokenBalanceAfter = conditionalTokens.balanceOf(address(this), uint256(positionId));
        uint256 tokensReceived = tokenBalanceAfter - tokenBalanceBefore;
        if (tokensReceived == 0) revert NoTokensReceived();

        // Credit outcome tokens to user
        positions[msg.sender][positionId] += tokensReceived;

        emit PositionBought(msg.sender, market, outcomeIndex, amount, tokensReceived);
    }

    /// @notice Sell outcome tokens on behalf of user via FPMM
    /// @dev Approves ConditionalTokens to FPMM, calls FPMM.sell(), debits outcome tokens,
    ///      credits USDC. Uses before/after balance snapshots for exact accounting.
    /// @param market Address of the FPMM market contract
    /// @param outcomeIndex 0 for Yes, 1 for No
    /// @param returnAmount USDC amount the user wants to receive
    /// @param maxOutcomeTokens Maximum outcome tokens to sell (slippage protection)
    function sellPosition(
        address market,
        uint256 outcomeIndex,
        uint256 returnAmount,
        uint256 maxOutcomeTokens
    ) external whenNotPaused nonReentrant {
        if (market == address(0)) revert ZeroAddress();
        if (returnAmount == 0) revert ZeroAmount();
        if (outcomeIndex > 1) revert InvalidOutcomeIndex(outcomeIndex);

        // Validate FPMM uses same collateral and ConditionalTokens
        _validateMarket(market);

        // Compute positionId for this outcome
        bytes32 positionId = _getPositionId(market, outcomeIndex);

        // Check user has enough outcome tokens (use maxOutcomeTokens as upper bound check)
        uint256 currentPosition = positions[msg.sender][positionId];
        if (maxOutcomeTokens > currentPosition) {
            revert InsufficientPositionBalance(maxOutcomeTokens, currentPosition);
        }

        // Snapshot ERC1155 balance before trade
        uint256 tokenBalanceBefore = conditionalTokens.balanceOf(address(this), uint256(positionId));

        // Approve ConditionalTokens (ERC1155) to FPMM for token transfer
        // FPMM.sell() calls conditionalTokens.safeTransferFrom(vault, ...) to pull tokens
        // Approval is granted per-sell and revoked after execution (least-privilege)
        conditionalTokens.setApprovalForAll(market, true);

        // Snapshot USDC balance before trade
        uint256 usdcBalanceBefore = collateralToken.balanceOf(address(this));

        // Execute sell
        IFPMM(market).sell(returnAmount, outcomeIndex, maxOutcomeTokens);

        // Revoke ERC1155 approval after sell to minimize persistent approvals
        conditionalTokens.setApprovalForAll(market, false);

        // Calculate actual tokens sold via before/after ERC1155 snapshot
        uint256 tokenBalanceAfter = conditionalTokens.balanceOf(address(this), uint256(positionId));
        uint256 tokensSold = tokenBalanceBefore - tokenBalanceAfter;

        // Calculate actual USDC received via before/after snapshot
        uint256 usdcBalanceAfter = collateralToken.balanceOf(address(this));
        uint256 usdcReceived = usdcBalanceAfter - usdcBalanceBefore;
        if (usdcReceived == 0) revert NoCollateralReceived();

        // Debit outcome tokens from user
        positions[msg.sender][positionId] = currentPosition - tokensSold;

        // Credit USDC to user
        balances[msg.sender] += usdcReceived;

        emit PositionSold(msg.sender, market, outcomeIndex, usdcReceived, tokensSold);
    }

    // ──────────────────────────────────────────────
    // Redemption
    // ──────────────────────────────────────────────

    /// @notice Redeem outcome tokens for USDC after a market has resolved
    /// @dev Uses a lazy redemption pattern to solve the CT full-burn problem:
    ///      ConditionalTokens.redeemPositions burns the ENTIRE vault balance for a position,
    ///      not per-user. The first user to redeem a position triggers the CT call and we store
    ///      a redemption rate (collateral per token, scaled by 1e18). Subsequent users skip
    ///      the CT call entirely and use the stored rate for their payout calculation.
    /// @param market Address of the FPMM market contract (to derive conditionId)
    /// @param indexSets Array of index sets to redeem (e.g., [1] for Yes, [2] for No, [1,2] for both)
    function redeemPosition(
        address market,
        uint256[] calldata indexSets
    ) external whenNotPaused nonReentrant {
        if (market == address(0)) revert ZeroAddress();

        // Validate FPMM uses same collateral and ConditionalTokens
        _validateMarket(market);

        bytes32 conditionId = IFPMM(market).conditionIds(0);
        uint256 len = indexSets.length;
        uint256 totalUserCollateral = 0;
        bool hasPositions = false;

        for (uint256 i = 0; i < len; i++) {
            // Compute positionId for this indexSet
            bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSets[i]);
            bytes32 positionId = bytes32(conditionalTokens.getPositionId(collateralToken, collectionId));

            // Skip positions where user has no tokens
            uint256 userTokens = positions[msg.sender][positionId];
            if (userTokens == 0) continue;

            hasPositions = true;

            // First redeemer for this position triggers the actual CT redemption
            if (!positionRedeemed[positionId]) {
                // Snapshot vault's ERC1155 balance before CT call
                uint256 vaultTokensBefore = conditionalTokens.balanceOf(address(this), uint256(positionId));

                // Snapshot USDC balance before CT call
                uint256 usdcBefore = collateralToken.balanceOf(address(this));

                // Redeem this single position via CT (burns ALL vault tokens for this positionId)
                uint256[] memory singleIndexSet = new uint256[](1);
                singleIndexSet[0] = indexSets[i];
                conditionalTokens.redeemPositions(collateralToken, bytes32(0), conditionId, singleIndexSet);

                // Snapshot after to compute collateral received and tokens burned
                uint256 usdcAfter = collateralToken.balanceOf(address(this));
                uint256 usdcReceived = usdcAfter - usdcBefore;
                uint256 vaultTokensAfter = conditionalTokens.balanceOf(address(this), uint256(positionId));
                uint256 tokensBurned = vaultTokensBefore - vaultTokensAfter;

                // Store rate: collateral per token scaled by 1e18 for precision
                if (tokensBurned > 0) {
                    redemptionRates[positionId] = (usdcReceived * 1e18) / tokensBurned;
                }

                positionRedeemed[positionId] = true;
            }

            // Credit user using stored rate (works for first AND subsequent redeemers)
            uint256 userCollateral = (userTokens * redemptionRates[positionId]) / 1e18;
            totalUserCollateral += userCollateral;

            // Debit user's position — fully redeemed
            positions[msg.sender][positionId] = 0;
        }

        // User must have at least some tokens to redeem
        if (!hasPositions) revert NoPositionsToRedeem();

        // Credit collateral to user balance
        if (totalUserCollateral > 0) {
            balances[msg.sender] += totalUserCollateral;
        }

        emit PositionRedeemed(msg.sender, market, totalUserCollateral);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @notice Returns the USDC balance of a user in the Vault
    /// @param user Address to query
    /// @return USDC balance (6 decimals)
    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }

    /// @notice Returns the outcome token position balance for a user
    /// @param user Address to query
    /// @param positionId ConditionalTokens position ID (keccak256 of collateral + collectionId)
    /// @return Amount of outcome tokens held
    function getPosition(address user, bytes32 positionId) external view returns (uint256) {
        return positions[user][positionId];
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    /// @notice Pause deposits and withdrawals
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause deposits and withdrawals
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue ERC20 tokens accidentally sent to this contract
    /// @dev Cannot rescue the collateral token (USDC) — only truly foreign tokens.
    ///      Collateral is tracked via internal balances and must not be drained.
    /// @param token Address of the ERC20 token to rescue
    /// @param to Destination address
    /// @param amount Amount of tokens to rescue
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(collateralToken)) revert RescueDenied();

        IERC20(token).safeTransfer(to, amount);

        emit TokensRescued(token, to, amount);
    }

    // ──────────────────────────────────────────────
    // ERC1155 Receiver
    // ──────────────────────────────────────────────

    /// @notice Override supportsInterface to resolve multiple inheritance
    /// @param interfaceId The interface identifier to check
    /// @return True if this contract supports the given interface
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ──────────────────────────────────────────────
    // Internal Helpers
    // ──────────────────────────────────────────────

    /// @dev Validates that an FPMM market uses the same collateral token and ConditionalTokens
    ///      as this Vault. Reverts if there is a mismatch.
    /// @param market Address of the FPMM market contract
    function _validateMarket(address market) internal view {
        address marketCollateral = IFPMM(market).collateralToken();
        if (marketCollateral != address(collateralToken)) {
            revert MarketCollateralMismatch(address(collateralToken), marketCollateral);
        }

        address marketCT = IFPMM(market).conditionalTokens();
        if (marketCT != address(conditionalTokens)) {
            revert MarketConditionalTokensMismatch(address(conditionalTokens), marketCT);
        }
    }

    /// @dev Computes the ConditionalTokens positionId for a given FPMM market and outcome index.
    ///      For binary markets: indexSet = 1 << outcomeIndex (1 for Yes, 2 for No).
    /// @param market Address of the FPMM market contract
    /// @param outcomeIndex 0 for Yes, 1 for No
    /// @return positionId The ERC1155 token ID on ConditionalTokens
    function _getPositionId(address market, uint256 outcomeIndex) internal view returns (bytes32) {
        bytes32 conditionId = IFPMM(market).conditionIds(0);
        uint256 indexSet = 1 << outcomeIndex;

        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 posId = conditionalTokens.getPositionId(collateralToken, collectionId);

        return bytes32(posId);
    }
}
