// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IMarketRewards } from "./interfaces/IMarketRewards.sol";

/// @title MarketRewards
/// @notice Handles sponsor deposits for market incentives and merkle-proof-based maker reward claims.
/// @dev Sponsors deposit USDC to incentivize trading on specific markets. Makers claim rebates via
///      merkle proofs generated off-chain by the backend relayer. Claims use a cumulative approach:
///      each leaf encodes the total earned amount, and the contract pays the delta vs. already claimed.
contract MarketRewards is IMarketRewards, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error SponsorAlreadyDeposited(bytes32 marketId, address sponsor);
    error SponsorNotFound(bytes32 marketId, address sponsor);
    error SponsorPeriodNotEnded(bytes32 marketId, uint256 endsAt);
    error SponsorAlreadyWithdrawn(bytes32 marketId, address sponsor);
    error InvalidMerkleProof();
    error NothingToClaim();

    // ──────────────────────────────────────────────
    // Immutable / External Contracts
    // ──────────────────────────────────────────────

    IERC20 public immutable usdc;

    // ──────────────────────────────────────────────
    // Reward State
    // ──────────────────────────────────────────────

    /// @notice Current merkle root for maker reward claims (set by owner/relayer)
    bytes32 public override merkleRoot;

    /// @notice Cumulative amount already claimed per maker address
    mapping(address => uint256) public override claimed;

    /// @notice marketId => sponsor => SponsorDeposit
    mapping(bytes32 => mapping(address => SponsorDeposit)) internal _sponsorDeposits;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address _usdc, address _owner) Ownable(_owner) {
        if (_usdc == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(_usdc);
    }

    // ──────────────────────────────────────────────
    // Sponsor Functions
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketRewards
    function depositSponsorRewards(bytes32 marketId, uint256 amount, uint256 durationDays)
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (durationDays == 0) revert ZeroDuration();

        SponsorDeposit storage deposit = _sponsorDeposits[marketId][msg.sender];
        if (deposit.amount != 0) {
            revert SponsorAlreadyDeposited(marketId, msg.sender);
        }

        uint256 endsAt = block.timestamp + (durationDays * 1 days);
        uint256 dailyRate = amount / durationDays;

        deposit.amount = amount;
        deposit.dailyRate = dailyRate;
        deposit.startedAt = block.timestamp;
        deposit.endsAt = endsAt;
        deposit.withdrawn = false;

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit SponsorDeposited(marketId, msg.sender, amount, durationDays);
    }

    /// @inheritdoc IMarketRewards
    function withdrawUnusedSponsor(bytes32 marketId) external override whenNotPaused nonReentrant {
        SponsorDeposit storage deposit = _sponsorDeposits[marketId][msg.sender];

        if (deposit.amount == 0) {
            revert SponsorNotFound(marketId, msg.sender);
        }
        if (deposit.withdrawn) {
            revert SponsorAlreadyWithdrawn(marketId, msg.sender);
        }
        if (block.timestamp < deposit.endsAt) {
            revert SponsorPeriodNotEnded(marketId, deposit.endsAt);
        }

        deposit.withdrawn = true;
        uint256 amount = deposit.amount;

        usdc.safeTransfer(msg.sender, amount);

        emit SponsorWithdrawn(marketId, msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    // Maker Claim
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketRewards
    function claimRewards(uint256 cumulativeAmount, bytes32[] calldata merkleProof)
        external
        override
        whenNotPaused
        nonReentrant
    {
        // 1. Verify merkle proof — leaf = keccak256(abi.encodePacked(maker, cumulativeAmount))
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, cumulativeAmount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, leaf)) {
            revert InvalidMerkleProof();
        }

        // 2. Calculate delta (new amount owed)
        uint256 alreadyClaimed = claimed[msg.sender];
        if (cumulativeAmount <= alreadyClaimed) {
            revert NothingToClaim();
        }
        uint256 delta = cumulativeAmount - alreadyClaimed;

        // 3. Update claimed mapping before transfer (CEI pattern)
        claimed[msg.sender] = cumulativeAmount;

        // 4. Transfer USDC
        usdc.safeTransfer(msg.sender, delta);

        emit RewardsClaimed(msg.sender, delta);
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketRewards
    function updateMerkleRoot(bytes32 newRoot) external override onlyOwner {
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }

    /// @notice Pause all reward operations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all reward operations
    function unpause() external onlyOwner {
        _unpause();
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IMarketRewards
    function sponsorDeposits(bytes32 marketId, address sponsor)
        external
        view
        override
        returns (uint256 amount, uint256 dailyRate, uint256 startedAt, uint256 endsAt, bool withdrawn)
    {
        SponsorDeposit storage deposit = _sponsorDeposits[marketId][sponsor];
        return (deposit.amount, deposit.dailyRate, deposit.startedAt, deposit.endsAt, deposit.withdrawn);
    }
}
