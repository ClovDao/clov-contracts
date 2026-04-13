// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketRewards } from "../src/MarketRewards.sol";
import { IMarketRewards } from "../src/interfaces/IMarketRewards.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Mock USDC with public mint and 6 decimals
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MarketRewardsTest is Test {
    MarketRewards public rewards;
    MockUSDC public usdc;

    address public owner;
    address public sponsor = makeAddr("sponsor");
    address public maker1 = makeAddr("maker1");
    address public maker2 = makeAddr("maker2");
    address public alice = makeAddr("alice");

    bytes32 public constant MARKET_ID = keccak256("market-1");

    uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant DURATION_DAYS = 30;

    function setUp() public {
        owner = address(this);
        usdc = new MockUSDC();

        rewards = new MarketRewards(address(usdc), owner);

        // Fund the rewards contract with USDC for claim tests
        usdc.mint(address(rewards), 10_000e6);
    }

    // ──────────────────────────────────────────────
    // Deployment
    // ──────────────────────────────────────────────

    function test_constructor_setsOwnerAndUsdc() public view {
        assertEq(address(rewards.usdc()), address(usdc));
        assertEq(rewards.owner(), owner);
    }

    function test_initialMerkleRootIsZero() public view {
        assertEq(rewards.merkleRoot(), bytes32(0));
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(MarketRewards.ZeroAddress.selector);
        new MarketRewards(address(0), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MarketRewards(address(usdc), address(0));
    }

    // ──────────────────────────────────────────────
    // Sponsor Deposits
    // ──────────────────────────────────────────────

    function test_depositSponsorRewards_success() public {
        usdc.mint(sponsor, DEPOSIT_AMOUNT);

        vm.startPrank(sponsor);
        usdc.approve(address(rewards), DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit IMarketRewards.SponsorDeposited(MARKET_ID, sponsor, DEPOSIT_AMOUNT, DURATION_DAYS);

        rewards.depositSponsorRewards(MARKET_ID, DEPOSIT_AMOUNT, DURATION_DAYS);
        vm.stopPrank();

        // Verify deposit stored correctly
        (uint256 amount, uint256 dailyRate, uint256 startedAt, uint256 endsAt, bool withdrawn) =
            rewards.sponsorDeposits(MARKET_ID, sponsor);

        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(dailyRate, DEPOSIT_AMOUNT / DURATION_DAYS);
        assertEq(startedAt, block.timestamp);
        assertEq(endsAt, block.timestamp + (DURATION_DAYS * 1 days));
        assertFalse(withdrawn);

        // USDC transferred from sponsor to contract
        assertEq(usdc.balanceOf(sponsor), 0);
    }

    function test_depositSponsorRewards_zeroAmount_reverts() public {
        vm.prank(sponsor);
        vm.expectRevert(MarketRewards.ZeroAmount.selector);
        rewards.depositSponsorRewards(MARKET_ID, 0, DURATION_DAYS);
    }

    function test_depositSponsorRewards_zeroDuration_reverts() public {
        vm.prank(sponsor);
        vm.expectRevert(MarketRewards.ZeroDuration.selector);
        rewards.depositSponsorRewards(MARKET_ID, DEPOSIT_AMOUNT, 0);
    }

    function test_depositSponsorRewards_duplicateDeposit_reverts() public {
        usdc.mint(sponsor, DEPOSIT_AMOUNT * 2);

        vm.startPrank(sponsor);
        usdc.approve(address(rewards), DEPOSIT_AMOUNT * 2);

        rewards.depositSponsorRewards(MARKET_ID, DEPOSIT_AMOUNT, DURATION_DAYS);

        vm.expectRevert(abi.encodeWithSelector(MarketRewards.SponsorAlreadyDeposited.selector, MARKET_ID, sponsor));
        rewards.depositSponsorRewards(MARKET_ID, DEPOSIT_AMOUNT, DURATION_DAYS);

        vm.stopPrank();
    }

    function test_depositSponsorRewards_whenPaused_reverts() public {
        rewards.pause();

        usdc.mint(sponsor, DEPOSIT_AMOUNT);
        vm.startPrank(sponsor);
        usdc.approve(address(rewards), DEPOSIT_AMOUNT);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        rewards.depositSponsorRewards(MARKET_ID, DEPOSIT_AMOUNT, DURATION_DAYS);

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Sponsor Withdrawal
    // ──────────────────────────────────────────────

    function _depositAsSponsor() internal {
        usdc.mint(sponsor, DEPOSIT_AMOUNT);

        vm.startPrank(sponsor);
        usdc.approve(address(rewards), DEPOSIT_AMOUNT);
        rewards.depositSponsorRewards(MARKET_ID, DEPOSIT_AMOUNT, DURATION_DAYS);
        vm.stopPrank();
    }

    function test_withdrawUnusedSponsor_afterEndDate() public {
        _depositAsSponsor();

        // Warp past the end date
        vm.warp(block.timestamp + (DURATION_DAYS * 1 days) + 1);

        uint256 sponsorBalanceBefore = usdc.balanceOf(sponsor);

        vm.expectEmit(true, true, false, true);
        emit IMarketRewards.SponsorWithdrawn(MARKET_ID, sponsor, DEPOSIT_AMOUNT);

        vm.prank(sponsor);
        rewards.withdrawUnusedSponsor(MARKET_ID);

        assertEq(usdc.balanceOf(sponsor), sponsorBalanceBefore + DEPOSIT_AMOUNT);

        // Verify withdrawn flag
        (,,,, bool withdrawn) = rewards.sponsorDeposits(MARKET_ID, sponsor);
        assertTrue(withdrawn);
    }

    function test_withdrawUnusedSponsor_beforeEndDate_reverts() public {
        _depositAsSponsor();

        (,,, uint256 endsAt,) = rewards.sponsorDeposits(MARKET_ID, sponsor);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(MarketRewards.SponsorPeriodNotEnded.selector, MARKET_ID, endsAt));
        rewards.withdrawUnusedSponsor(MARKET_ID);
    }

    function test_withdrawUnusedSponsor_notSponsor_reverts() public {
        _depositAsSponsor();

        // Warp past end date
        vm.warp(block.timestamp + (DURATION_DAYS * 1 days) + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketRewards.SponsorNotFound.selector, MARKET_ID, alice));
        rewards.withdrawUnusedSponsor(MARKET_ID);
    }

    function test_withdrawUnusedSponsor_alreadyWithdrawn_reverts() public {
        _depositAsSponsor();

        // Warp past end date
        vm.warp(block.timestamp + (DURATION_DAYS * 1 days) + 1);

        vm.prank(sponsor);
        rewards.withdrawUnusedSponsor(MARKET_ID);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(MarketRewards.SponsorAlreadyWithdrawn.selector, MARKET_ID, sponsor));
        rewards.withdrawUnusedSponsor(MARKET_ID);
    }

    // ──────────────────────────────────────────────
    // Merkle Root
    // ──────────────────────────────────────────────

    function test_updateMerkleRoot_success() public {
        bytes32 newRoot = keccak256("new-root");

        vm.expectEmit(false, false, false, true);
        emit IMarketRewards.MerkleRootUpdated(newRoot);

        rewards.updateMerkleRoot(newRoot);

        assertEq(rewards.merkleRoot(), newRoot);
    }

    function test_updateMerkleRoot_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.updateMerkleRoot(keccak256("bad-root"));
    }

    // ──────────────────────────────────────────────
    // Claim Rewards (Merkle Proof)
    // ──────────────────────────────────────────────

    /// @dev Helper: compute a sorted pair hash for a 2-leaf merkle tree
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        if (a < b) {
            return keccak256(abi.encodePacked(a, b));
        } else {
            return keccak256(abi.encodePacked(b, a));
        }
    }

    /// @dev Helper: set up a 2-leaf merkle tree and return (root, leaf1, leaf2)
    function _buildMerkleTree(address _maker1, uint256 _amount1, address _maker2, uint256 _amount2)
        internal
        pure
        returns (bytes32 root, bytes32 leaf1, bytes32 leaf2)
    {
        leaf1 = keccak256(abi.encodePacked(_maker1, _amount1));
        leaf2 = keccak256(abi.encodePacked(_maker2, _amount2));
        root = _hashPair(leaf1, leaf2);
    }

    function test_claimRewards_validProof() public {
        uint256 maker1Amount = 100e6;
        uint256 maker2Amount = 50e6;

        (bytes32 root,, bytes32 leaf2) = _buildMerkleTree(maker1, maker1Amount, maker2, maker2Amount);

        // Set the merkle root
        rewards.updateMerkleRoot(root);

        uint256 maker1BalanceBefore = usdc.balanceOf(maker1);

        // maker1 claims with leaf2 as proof
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.expectEmit(true, false, false, true);
        emit IMarketRewards.RewardsClaimed(maker1, maker1Amount);

        vm.prank(maker1);
        rewards.claimRewards(maker1Amount, proof);

        assertEq(usdc.balanceOf(maker1), maker1BalanceBefore + maker1Amount);
        assertEq(rewards.claimed(maker1), maker1Amount);
    }

    function test_claimRewards_invalidProof_reverts() public {
        uint256 maker1Amount = 100e6;
        uint256 maker2Amount = 50e6;

        (bytes32 root,,) = _buildMerkleTree(maker1, maker1Amount, maker2, maker2Amount);

        rewards.updateMerkleRoot(root);

        // Use a wrong proof
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("garbage");

        vm.prank(maker1);
        vm.expectRevert(MarketRewards.InvalidMerkleProof.selector);
        rewards.claimRewards(maker1Amount, badProof);
    }

    function test_claimRewards_alreadyClaimed_reverts() public {
        uint256 maker1Amount = 100e6;
        uint256 maker2Amount = 50e6;

        (bytes32 root,, bytes32 leaf2) = _buildMerkleTree(maker1, maker1Amount, maker2, maker2Amount);

        rewards.updateMerkleRoot(root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        // First claim succeeds
        vm.prank(maker1);
        rewards.claimRewards(maker1Amount, proof);

        // Second claim with same cumulative amount reverts (delta = 0)
        vm.prank(maker1);
        vm.expectRevert(MarketRewards.NothingToClaim.selector);
        rewards.claimRewards(maker1Amount, proof);
    }

    function test_claimRewards_partialClaim() public {
        // Phase 1: Merkle tree with maker1 = 50 USDC
        uint256 firstAmount = 50e6;
        uint256 maker2Amount = 30e6;

        (bytes32 root1,, bytes32 leaf2_v1) = _buildMerkleTree(maker1, firstAmount, maker2, maker2Amount);

        rewards.updateMerkleRoot(root1);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2_v1;

        vm.prank(maker1);
        rewards.claimRewards(firstAmount, proof1);

        assertEq(usdc.balanceOf(maker1), firstAmount);
        assertEq(rewards.claimed(maker1), firstAmount);

        // Phase 2: Updated merkle tree with maker1 = 100 USDC (cumulative)
        uint256 secondAmount = 100e6;
        uint256 maker2Amount_v2 = 60e6;

        (bytes32 root2,, bytes32 leaf2_v2) = _buildMerkleTree(maker1, secondAmount, maker2, maker2Amount_v2);

        rewards.updateMerkleRoot(root2);

        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = leaf2_v2;

        vm.expectEmit(true, false, false, true);
        emit IMarketRewards.RewardsClaimed(maker1, secondAmount - firstAmount);

        vm.prank(maker1);
        rewards.claimRewards(secondAmount, proof2);

        // maker1 should have received the delta (50 USDC more)
        assertEq(usdc.balanceOf(maker1), secondAmount);
        assertEq(rewards.claimed(maker1), secondAmount);
    }

    function test_claimRewards_whenPaused_reverts() public {
        uint256 maker1Amount = 100e6;
        uint256 maker2Amount = 50e6;

        (bytes32 root,, bytes32 leaf2) = _buildMerkleTree(maker1, maker1Amount, maker2, maker2Amount);

        rewards.updateMerkleRoot(root);
        rewards.pause();

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        vm.prank(maker1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        rewards.claimRewards(maker1Amount, proof);
    }

    // ──────────────────────────────────────────────
    // Pause / Unpause
    // ──────────────────────────────────────────────

    function test_pause_unpause() public {
        rewards.pause();
        assertTrue(rewards.paused());

        rewards.unpause();
        assertFalse(rewards.paused());
    }

    function test_pause_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.pause();
    }

    function test_unpause_nonOwner_reverts() public {
        rewards.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.unpause();
    }
}
