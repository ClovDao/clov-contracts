// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { ClovOracleAdapter } from "../src/ClovOracleAdapter.sol";
import { MarketResolver } from "../src/MarketResolver.sol";
import { Vault } from "../src/Vault.sol";

/// @title Deploy — Clov Protocol full deployment to Polygon Amoy
/// @notice Deploys Gnosis ConditionalTokens + FPMMDeterministicFactory (not available on Amoy),
///         then deploys MarketFactory, ClovOracleAdapter, MarketResolver, and wires them together.
/// @dev Usage: forge script script/Deploy.s.sol --rpc-url amoy --broadcast
contract Deploy is Script {
    // ── External addresses on Amoy (confirmed) ──
    address constant USDC = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582;
    address constant UMA_ORACLE_V3 = 0xd8866E76441df243fc98B892362Fc6264dC3ca80;

    // ── Configuration ──
    uint256 constant CREATION_DEPOSIT = 5e6; // 5 USDC (6 decimals)
    uint256 constant TRADING_FEE = 200; // 2% in basis points
    uint256 constant BOND_AMOUNT = 1e6; // 1 USDC bond for UMA assertions
    uint64 constant ASSERTION_LIVENESS = 7200; // 2 hours dispute window

    // ──────────────────────────────────────────────────────────────────────────
    // MAINNET DEPLOYMENT WARNING
    // ──────────────────────────────────────────────────────────────────────────
    // This script uses a raw private key (PRIVATE_KEY env var) and is intended
    // for TESTNET deployments ONLY (Polygon Amoy, chain ID 80002).
    //
    // For mainnet / production deployment:
    //   1. Use a hardware wallet (Ledger / Trezor) via --ledger flag.
    //   2. Deploy behind a Safe (Gnosis Safe) multisig with an appropriate
    //      threshold (e.g. 2-of-3 or 3-of-5).
    //   3. Transfer contract ownership to the multisig immediately after deploy.
    //   4. Never expose private keys in environment variables on production
    //      machines.
    // ──────────────────────────────────────────────────────────────────────────

    function run() external {
        // Chain ID guard — prevent accidental mainnet deployment
        require(block.chainid == 80002, "TESTNET ONLY: Amoy chain ID required");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Clov Protocol Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ── Step 1: Deploy Gnosis ConditionalTokens ──
        // These contracts are compiled with solc 0.5.x; we deploy via raw bytecode
        address conditionalTokens = _deployFromArtifact(
            "conditional-tokens-contracts/contracts/ConditionalTokens.sol:ConditionalTokens"
        );
        console.log("ConditionalTokens:", conditionalTokens);

        // ── Step 2: Deploy Gnosis FPMMDeterministicFactory ──
        address fpmmFactory = _deployFromArtifact(
            "conditional-tokens-market-makers/contracts/FPMMDeterministicFactory.sol:FPMMDeterministicFactory"
        );
        console.log("FPMMDeterministicFactory:", fpmmFactory);

        // ── Step 3: Deploy MarketFactory (without cross-references) ──
        MarketFactory marketFactory = new MarketFactory(
            USDC,
            conditionalTokens,
            fpmmFactory,
            CREATION_DEPOSIT,
            TRADING_FEE
        );
        console.log("MarketFactory:", address(marketFactory));

        // ── Step 4: Deploy ClovOracleAdapter (without cross-references) ──
        ClovOracleAdapter oracleAdapter = new ClovOracleAdapter(
            UMA_ORACLE_V3,
            USDC, // bond token = USDC
            BOND_AMOUNT,
            ASSERTION_LIVENESS
        );
        console.log("ClovOracleAdapter:", address(oracleAdapter));

        // ── Step 5: Deploy MarketResolver (without cross-references) ──
        MarketResolver marketResolver = new MarketResolver(conditionalTokens);
        console.log("MarketResolver:", address(marketResolver));

        // ── Step 6: Deploy Vault ──
        Vault vault = new Vault(USDC, conditionalTokens);
        console.log("Vault:", address(vault));

        // ── Step 7: Wire cross-references via initialize() ──
        marketFactory.initialize(address(oracleAdapter), address(marketResolver));
        console.log("MarketFactory initialized");

        oracleAdapter.initialize(address(marketFactory), address(marketResolver));
        console.log("ClovOracleAdapter initialized");

        marketResolver.initialize(address(marketFactory), address(oracleAdapter));
        console.log("MarketResolver initialized");

        vm.stopBroadcast();

        // ── Summary ──
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("ConditionalTokens:         ", conditionalTokens);
        console.log("FPMMDeterministicFactory:   ", fpmmFactory);
        console.log("MarketFactory:              ", address(marketFactory));
        console.log("ClovOracleAdapter:          ", address(oracleAdapter));
        console.log("MarketResolver:             ", address(marketResolver));
        console.log("Vault:                      ", address(vault));
        console.log("USDC (collateral + bond):   ", USDC);
        console.log("UMA OptimisticOracleV3:     ", UMA_ORACLE_V3);
        console.log("=== All contracts deployed and wired ===");
    }

    /// @dev Deploys a contract from its Foundry compilation artifact using vm.getCode
    function _deployFromArtifact(string memory artifactPath) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifactPath);
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), string.concat("Failed to deploy: ", artifactPath));
    }
}
