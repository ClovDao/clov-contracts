// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IMarketRewards {
    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    struct SponsorDeposit {
        uint256 amount;
        uint256 dailyRate;
        uint256 startedAt;
        uint256 endsAt;
        bool withdrawn;
    }

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event SponsorDeposited(bytes32 indexed marketId, address indexed sponsor, uint256 amount, uint256 durationDays);
    event SponsorWithdrawn(bytes32 indexed marketId, address indexed sponsor, uint256 amount);
    event RewardsClaimed(address indexed maker, uint256 amount);
    event MerkleRootUpdated(bytes32 newRoot);

    // ──────────────────────────────────────────────
    // Sponsor Functions
    // ──────────────────────────────────────────────

    function depositSponsorRewards(bytes32 marketId, uint256 amount, uint256 durationDays) external;
    function withdrawUnusedSponsor(bytes32 marketId) external;

    // ──────────────────────────────────────────────
    // Maker Claim
    // ──────────────────────────────────────────────

    function claimRewards(uint256 cumulativeAmount, bytes32[] calldata merkleProof) external;

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function updateMerkleRoot(bytes32 newRoot) external;

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function merkleRoot() external view returns (bytes32);
    function claimed(address maker) external view returns (uint256);
    function sponsorDeposits(bytes32 marketId, address sponsor)
        external
        view
        returns (uint256 amount, uint256 dailyRate, uint256 startedAt, uint256 endsAt, bool withdrawn);
}
