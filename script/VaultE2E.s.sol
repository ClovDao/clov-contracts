// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vault } from "../src/Vault.sol";
import { IFPMM } from "../src/interfaces/IFPMM.sol";
import { IConditionalTokens } from "../src/interfaces/IConditionalTokens.sol";

/// @title VaultE2E — End-to-end Vault flow on Polygon Amoy
/// @notice Runs the full deposit -> buy -> sell -> withdraw flow against deployed contracts.
/// @dev Usage: forge script script/VaultE2E.s.sol --rpc-url amoy --broadcast -vvvv
///
///      Required .env variables:
///        PRIVATE_KEY          - funded wallet on Amoy (needs USDC + MATIC for gas)
///        VAULT_ADDRESS        - deployed Vault contract
///        USDC_ADDRESS         - USDC on Amoy
///        MARKET_ADDRESS       - an existing FPMM market with liquidity
///        CONDITIONAL_TOKENS   - deployed ConditionalTokens contract
contract VaultE2E is Script {
    // ── Configurable amounts (USDC has 6 decimals) ──
    uint256 constant DEPOSIT_AMOUNT = 10e6; // 10 USDC
    uint256 constant BUY_AMOUNT = 5e6; // 5 USDC
    uint256 constant SELL_RETURN = 2e6; // 2 USDC expected return from sell

    function run() external {
        // ── Load addresses from environment ──
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(deployerKey);

        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        address marketAddr = vm.envAddress("MARKET_ADDRESS");
        address ctAddr = vm.envAddress("CONDITIONAL_TOKENS");

        Vault vault = Vault(vaultAddr);
        IERC20 usdc = IERC20(usdcAddr);
        IFPMM market = IFPMM(marketAddr);
        IConditionalTokens ct = IConditionalTokens(ctAddr);

        console.log("========================================");
        console.log("  Clov Vault E2E - Polygon Amoy");
        console.log("========================================");
        console.log("User:              ", user);
        console.log("Vault:             ", vaultAddr);
        console.log("USDC:              ", usdcAddr);
        console.log("Market (FPMM):     ", marketAddr);
        console.log("ConditionalTokens: ", ctAddr);
        console.log("");

        // ── Pre-flight checks ──
        uint256 usdcBalance = usdc.balanceOf(user);
        console.log("[Pre-flight] User USDC balance:", usdcBalance);
        require(usdcBalance >= DEPOSIT_AMOUNT, "E2E: insufficient USDC balance for deposit");

        // Compute positionId for YES outcome (outcomeIndex=0, indexSet=1)
        bytes32 conditionId = market.conditionIds(0);
        bytes32 collectionId = ct.getCollectionId(bytes32(0), conditionId, 1);
        uint256 positionIdUint = ct.getPositionId(usdc, collectionId);
        bytes32 positionId = bytes32(positionIdUint);

        console.log("[Pre-flight] conditionId:");
        console.logBytes32(conditionId);
        console.log("[Pre-flight] YES positionId:", positionIdUint);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ────────────────────────────────────────────────
        // Step 1: Approve USDC and Deposit
        // ────────────────────────────────────────────────
        console.log("=== Step 1: Deposit 10 USDC ===");
        usdc.approve(vaultAddr, DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);

        uint256 vaultBalance = vault.balanceOf(user);
        console.log("  vault.balanceOf(user):", vaultBalance);
        require(vaultBalance == DEPOSIT_AMOUNT, "E2E: vault balance should be 10 USDC after deposit");
        console.log("  [PASS] Deposit verified");
        console.log("");

        // ────────────────────────────────────────────────
        // Step 2: Buy YES position (5 USDC)
        // ────────────────────────────────────────────────
        console.log("=== Step 2: Buy YES position (5 USDC) ===");
        // minOutcomeTokens = 0 to avoid slippage revert on testnet
        vault.buyPosition(marketAddr, 0, BUY_AMOUNT, 0);

        uint256 balanceAfterBuy = vault.balanceOf(user);
        uint256 positionAfterBuy = vault.getPosition(user, positionId);
        console.log("  vault.balanceOf(user):", balanceAfterBuy);
        console.log("  vault.getPosition(user, positionId):", positionAfterBuy);
        require(balanceAfterBuy == DEPOSIT_AMOUNT - BUY_AMOUNT, "E2E: balance should be 5 USDC after buy");
        require(positionAfterBuy > 0, "E2E: should have outcome tokens after buy");
        console.log("  [PASS] Buy verified");
        console.log("");

        // ────────────────────────────────────────────────
        // Step 3: Sell part of YES position (return 2 USDC)
        // ────────────────────────────────────────────────
        console.log("=== Step 3: Sell YES position (return 2 USDC) ===");
        // maxOutcomeTokens = full position to allow the AMM flexibility
        uint256 maxTokensForSell = positionAfterBuy;
        vault.sellPosition(marketAddr, 0, SELL_RETURN, maxTokensForSell);

        uint256 balanceAfterSell = vault.balanceOf(user);
        uint256 positionAfterSell = vault.getPosition(user, positionId);
        console.log("  vault.balanceOf(user):", balanceAfterSell);
        console.log("  vault.getPosition(user, positionId):", positionAfterSell);
        require(balanceAfterSell > balanceAfterBuy, "E2E: balance should increase after sell");
        require(positionAfterSell < positionAfterBuy, "E2E: position should decrease after sell");
        console.log("  [PASS] Sell verified");
        console.log("");

        // ────────────────────────────────────────────────
        // Step 4: Withdraw remaining USDC balance
        // ────────────────────────────────────────────────
        console.log("=== Step 4: Withdraw remaining USDC ===");
        uint256 remainingBalance = vault.balanceOf(user);
        console.log("  Withdrawing:", remainingBalance);
        vault.withdraw(remainingBalance);

        uint256 finalVaultBalance = vault.balanceOf(user);
        console.log("  vault.balanceOf(user) after withdraw:", finalVaultBalance);
        require(finalVaultBalance == 0, "E2E: vault balance should be 0 after full withdraw");
        console.log("  [PASS] Withdraw verified");
        console.log("");

        vm.stopBroadcast();

        // ────────────────────────────────────────────────
        // Summary
        // ────────────────────────────────────────────────
        console.log("========================================");
        console.log("  E2E COMPLETE - ALL CHECKS PASSED");
        console.log("========================================");
        console.log("  Deposited:       ", DEPOSIT_AMOUNT);
        console.log("  Bought YES for:  ", BUY_AMOUNT);
        console.log("  Tokens received: ", positionAfterBuy);
        console.log("  Sold for return: ", SELL_RETURN);
        console.log("  Tokens remaining:", positionAfterSell);
        console.log("  Withdrawn:       ", remainingBalance);
        console.log("  Final balance:   ", finalVaultBalance);
        console.log("");
        console.log("  NOTE: User still holds", positionAfterSell, "outcome tokens in the Vault.");
        console.log("  These can be redeemed after market resolution via vault.redeemPosition().");
    }
}
