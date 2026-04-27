// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CTFExchange } from "../src/exchange/CTFExchange.sol";
import { NegRiskCtfExchange } from "../src/neg-risk/NegRiskCtfExchange.sol";
import { NegRiskAdapter } from "../src/neg-risk/NegRiskAdapter.sol";

/// @title DeployExchanges — surgical redeploy of CTFExchange + NegRiskCtfExchange on Amoy
/// @notice The exchange contracts predate the
///         POLY_PROXY signature branch + proxyFactory immutable. This script
///         redeploys ONLY those two contracts, wired to the existing CT,
///         USDC, NegRiskAdapter, SafeFactory, and ProxyWalletFactory
///         addresses on Amoy.
/// @dev Usage: forge script script/DeployExchanges.s.sol --rpc-url amoy --broadcast
contract DeployExchanges is Script {
    // ── Existing infrastructure on Amoy (from packages/shared/src/constants.ts) ──
    address constant USDC = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582;
    address constant CONDITIONAL_TOKENS = 0x5d28f2cd7665ecFD34D451B4d826c8adAcA2c4b5;
    address constant SAFE_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant PROXY_FACTORY = 0x8717380E786f9b7b89509bBe5B2b08e8995366f1;
    address constant NEG_RISK_ADAPTER = 0xE65d5Cfda8Dbdb54F95181aF6794e512C3DE092a;

    function run() external {
        require(block.chainid == 80002, "TESTNET ONLY: Amoy chain ID required");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Redeploying CTFExchange + NegRiskCtfExchange ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");
        console.log("Reusing existing infrastructure:");
        console.log("  USDC:              ", USDC);
        console.log("  ConditionalTokens: ", CONDITIONAL_TOKENS);
        console.log("  SafeFactory:       ", SAFE_FACTORY);
        console.log("  ProxyFactory:      ", PROXY_FACTORY);
        console.log("  NegRiskAdapter:    ", NEG_RISK_ADAPTER);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ── CTFExchange (binary) ──
        CTFExchange ctfExchange = new CTFExchange(USDC, CONDITIONAL_TOKENS, SAFE_FACTORY, PROXY_FACTORY);
        console.log("CTFExchange deployed at:        ", address(ctfExchange));

        // ── NegRiskCtfExchange (multi-outcome) ──
        NegRiskCtfExchange negRiskCtfExchange =
            new NegRiskCtfExchange(USDC, CONDITIONAL_TOKENS, NEG_RISK_ADAPTER, SAFE_FACTORY, PROXY_FACTORY);
        console.log("NegRiskCtfExchange deployed at: ", address(negRiskCtfExchange));

        // Deployer is auto-admin (Auth.sol constructor) and also auto-operator.
        // The original Deploy.s.sol added deployer as operator explicitly — no-op here
        // since constructor already does it, but kept for parity in case auth changes.
        // ctfExchange.addOperator(deployer);
        // negRiskCtfExchange.addOperator(deployer);

        // NegRiskAdapter.safeTransferFrom is onlyAdmin on the adapter's own Auth
        // module. The exchange MUST be admin there so _transferCTF (used when the
        // exchange moves minted positions back to makers) succeeds. Without this
        // any matchOrders MINT path reverts with NotAdmin().
        NegRiskAdapter(NEG_RISK_ADAPTER).addAdmin(address(negRiskCtfExchange));

        vm.stopBroadcast();

        console.log("");
        console.log("=== DONE ===");
        console.log("Update packages/shared/src/constants.ts with:");
        console.log("  ctfExchange:        ", address(ctfExchange));
        console.log("  negRiskCtfExchange: ", address(negRiskCtfExchange));
        console.log("");
        console.log("Then update apps/api/src/services/indexer.ts constants with the same addresses.");
        console.log("After that, re-run pnpm e2e:register-token to register a fresh tokenId on the new exchange.");
    }
}
