// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { ClovOracleAdapter } from "../src/ClovOracleAdapter.sol";
import { MarketResolver } from "../src/MarketResolver.sol";
import { CTFExchange } from "../src/exchange/CTFExchange.sol";
import { NegRiskAdapter } from "../src/neg-risk/NegRiskAdapter.sol";
import { NegRiskOperator } from "../src/neg-risk/NegRiskOperator.sol";
import { NegRiskCtfExchange } from "../src/neg-risk/NegRiskCtfExchange.sol";
import { ClovNegRiskOracle } from "../src/neg-risk/ClovNegRiskOracle.sol";
import { NegRiskCommunityRegistry } from "../src/neg-risk/NegRiskCommunityRegistry.sol";
import { Vault } from "../src/neg-risk/Vault.sol";
import { ProxyWalletImplementation } from "../src/ProxyWalletImplementation.sol";
import { ProxyWalletFactory } from "../src/ProxyWalletFactory.sol";
import { MarketRewards } from "../src/MarketRewards.sol";
import { ClovCommunityExecutor } from "../src/ClovCommunityExecutor.sol";

/// @title Deploy — Clov Protocol full deployment to Polygon Amoy
/// @notice Deploys Gnosis ConditionalTokens (not available on Amoy),
///         then deploys MarketFactory, ClovOracleAdapter, MarketResolver, and wires them together.
///         Phase H.2 adds the NegRiskCommunityRegistry and authorises it as admin on
///         NegRiskOperator so the community-tier incentive layer can orchestrate
///         permissionless NegRisk market creation.
/// @dev Usage: forge script script/Deploy.s.sol --rpc-url amoy --broadcast
///      Clov 2.0: FPMM removed. Trading is handled by the CTF Exchange CLOB
///      (deployed separately in Phase C).
contract Deploy is Script {
    // ── External addresses on Amoy (confirmed) ──
    address constant USDC = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582;
    address constant UMA_ORACLE_V3 = 0xd8866E76441df243fc98B892362Fc6264dC3ca80;

    // Gnosis Safe proxy factory on Amoy — needed for EIP-712 signature verification
    address constant SAFE_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;

    // ── Configuration ──
    uint256 constant CREATION_DEPOSIT = 1e6; // 1 USDC (6 decimals) — matches MIN_CREATION_DEPOSIT
    uint256 constant BOND_AMOUNT = 1000e6; // 1000 USDC bond for UMA outcome assertions
    uint256 constant CHALLENGE_BOND_AMOUNT = 500e6; // 500 USDC bond for Community challenge assertions
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
        address conditionalTokens =
            _deployFromArtifact("conditional-tokens-contracts/contracts/ConditionalTokens.sol:ConditionalTokens");
        console.log("ConditionalTokens:", conditionalTokens);

        // ── Step 2a: Deploy Vault (NegRisk fee vault) — needed before ProxyWallet wiring ──
        Vault vault = new Vault();
        console.log("Vault:", address(vault));

        // ── Step 2b: Deploy ProxyWallet implementation + factory ──
        ProxyWalletImplementation proxyImpl = new ProxyWalletImplementation();
        console.log("ProxyWalletImplementation:", address(proxyImpl));
        ProxyWalletFactory proxyFactory = new ProxyWalletFactory(address(proxyImpl));
        console.log("ProxyWalletFactory:", address(proxyFactory));

        // ── Step 2c: Deploy CTFExchange (binary CLOB) — address is immutable on MarketFactory ──
        CTFExchange ctfExchange = new CTFExchange(USDC, conditionalTokens, SAFE_FACTORY, address(proxyFactory));
        console.log("CTFExchange:", address(ctfExchange));

        // ── Step 3: Deploy MarketFactory with immutable ctfExchange pointer ──
        MarketFactory marketFactory = new MarketFactory(USDC, conditionalTokens, address(ctfExchange), CREATION_DEPOSIT);
        console.log("MarketFactory:", address(marketFactory));

        // ── Step 3b: Grant MarketFactory admin role on CTFExchange so it can call registerToken ──
        ctfExchange.addAdmin(address(marketFactory));
        console.log("CTFExchange: MarketFactory authorised as admin");

        // ── Step 4: Deploy ClovOracleAdapter (outcome bond + challenge bond) ──
        ClovOracleAdapter oracleAdapter = new ClovOracleAdapter(
            UMA_ORACLE_V3,
            USDC, // bond token = USDC
            BOND_AMOUNT,
            CHALLENGE_BOND_AMOUNT,
            ASSERTION_LIVENESS
        );
        console.log("ClovOracleAdapter:", address(oracleAdapter));

        // ── Step 5: Deploy MarketResolver (without cross-references) ──
        MarketResolver marketResolver = new MarketResolver(conditionalTokens);
        console.log("MarketResolver:", address(marketResolver));

        // ── Step 6: Wire cross-references via initialize() ──
        marketFactory.initialize(address(oracleAdapter), address(marketResolver));
        console.log("MarketFactory initialized");

        oracleAdapter.initialize(address(marketFactory), address(marketResolver));
        console.log("ClovOracleAdapter initialized");

        marketResolver.initialize(address(marketFactory), address(oracleAdapter));
        console.log("MarketResolver initialized");

        // ── Step 8: Deploy NegRiskAdapter ──
        NegRiskAdapter negRiskAdapter = new NegRiskAdapter(conditionalTokens, USDC, address(vault));
        console.log("NegRiskAdapter:", address(negRiskAdapter));

        // ── Step 8b: Authorize NegRiskAdapter as Vault admin ──
        vault.addAdmin(address(negRiskAdapter));
        console.log("Vault: NegRiskAdapter authorized as admin");

        // ── Step 9: Deploy NegRiskOperator ──
        NegRiskOperator negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        console.log("NegRiskOperator:", address(negRiskOperator));

        // ── Step 10: Deploy NegRiskCtfExchange ──
        NegRiskCtfExchange negRiskCtfExchange = new NegRiskCtfExchange(
            USDC, conditionalTokens, address(negRiskAdapter), SAFE_FACTORY, address(proxyFactory)
        );
        console.log("NegRiskCtfExchange:", address(negRiskCtfExchange));

        // ── Step 11: Deploy ClovNegRiskOracle ──
        ClovNegRiskOracle clovNegRiskOracle = new ClovNegRiskOracle(
            UMA_ORACLE_V3,
            USDC, // bond token
            address(negRiskOperator),
            BOND_AMOUNT,
            CHALLENGE_BOND_AMOUNT,
            ASSERTION_LIVENESS
        );
        console.log("ClovNegRiskOracle:", address(clovNegRiskOracle));

        // ── Step 12: Wire NegRiskOperator → ClovNegRiskOracle (one-time, irreversible) ──
        negRiskOperator.setOracle(address(clovNegRiskOracle));
        console.log("NegRiskOperator oracle set");

        // ── Step 13: Add deployer as operator on CTFExchange ──
        ctfExchange.addOperator(deployer);
        console.log("CTFExchange operator added:", deployer);

        // ── Step 14: Add deployer as operator on NegRiskCtfExchange ──
        negRiskCtfExchange.addOperator(deployer);
        console.log("NegRiskCtfExchange operator added:", deployer);

        // ── Step 15: Deploy NegRiskCommunityRegistry (H.2.13 + H.3.5) ──
        // Community-tier incentive layer for NegRisk markets: permissionless
        // creation with deposit escrow, 48h challenge window, creator-fee accrual.
        // Mirrors MarketFactory's Community surface but keyed by bytes32 nrMarketId.
        NegRiskCommunityRegistry negRiskCommunityRegistry = new NegRiskCommunityRegistry(
            USDC, address(negRiskOperator), address(negRiskAdapter), address(negRiskCtfExchange)
        );
        console.log("NegRiskCommunityRegistry:", address(negRiskCommunityRegistry));

        // ── Step 15b: Wire the oracle onto the registry (one-time) ──
        negRiskCommunityRegistry.setOracle(address(clovNegRiskOracle));
        console.log("NegRiskCommunityRegistry oracle wired");

        // ── Step 15c: Wire the registry onto the oracle (one-time, enables challenge routing) ──
        clovNegRiskOracle.setCommunityRegistry(address(negRiskCommunityRegistry));
        console.log("ClovNegRiskOracle registry wired");

        // ── Step 16: Authorize registry as admin on NegRiskOperator ──
        // Required so the registry can call `prepareCommunityMarket`,
        // `prepareCommunityQuestion`, `clearCommunityPermissionlessAssertion`,
        // and `setCommunityPermissionlessAssertion` on behalf of its market creators.
        negRiskOperator.addAdmin(address(negRiskCommunityRegistry));
        console.log("NegRiskOperator: NegRiskCommunityRegistry authorized as admin");

        // ── Step 16b: Authorize registry as admin on NegRiskCtfExchange ──
        // Required so `activateMarket` can call `registerToken` for each question.
        negRiskCtfExchange.addAdmin(address(negRiskCommunityRegistry));
        console.log("NegRiskCtfExchange: NegRiskCommunityRegistry authorised as admin");

        // ── Steps 17-19: Community layer (MarketRewards + Executor + exchange wiring) ──
        // Extracted into a helper to keep `run()` below the Solidity stack-too-deep
        // threshold (~16 local variables).
        (MarketRewards marketRewards, ClovCommunityExecutor executor, address protocolTreasury) =
            _deployCommunityLayer(ctfExchange, negRiskCtfExchange, marketFactory, negRiskCommunityRegistry, deployer);

        vm.stopBroadcast();

        // ── Summary ──
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("ConditionalTokens:         ", conditionalTokens);
        console.log("MarketFactory:              ", address(marketFactory));
        console.log("ClovOracleAdapter:          ", address(oracleAdapter));
        console.log("MarketResolver:             ", address(marketResolver));
        console.log("Vault:                      ", address(vault));
        console.log("CTFExchange:                ", address(ctfExchange));
        console.log("NegRiskAdapter:             ", address(negRiskAdapter));
        console.log("NegRiskOperator:            ", address(negRiskOperator));
        console.log("NegRiskCtfExchange:         ", address(negRiskCtfExchange));
        console.log("ClovNegRiskOracle:          ", address(clovNegRiskOracle));
        console.log("NegRiskCommunityRegistry:   ", address(negRiskCommunityRegistry));
        console.log("MarketRewards:              ", address(marketRewards));
        console.log("ClovCommunityExecutor:      ", address(executor));
        console.log("protocolTreasury:           ", protocolTreasury);
        console.log("USDC (collateral + bond):   ", USDC);
        console.log("UMA OptimisticOracleV3:     ", UMA_ORACLE_V3);
        console.log("Safe Factory:               ", SAFE_FACTORY);
        console.log("=== All contracts deployed and wired ===");
        console.log("");
        console.log("Post-deploy: on each Community market created via MarketFactory,");
        console.log("  call ctfExchange.setFee(marketId, 0) (or negRiskCtfExchange.setFee)");
        console.log("  so the exchange charges nothing and the executor is the sole fee path.");
    }

    /// @dev Deploys MarketRewards + ClovCommunityExecutor and wires the executor as
    ///      operator on both exchanges. Split out of `run()` to avoid the EVM
    ///      stack-too-deep error.
    function _deployCommunityLayer(
        CTFExchange ctfExchange,
        NegRiskCtfExchange negRiskCtfExchange,
        MarketFactory marketFactory,
        NegRiskCommunityRegistry negRiskCommunityRegistry,
        address deployer
    ) internal returns (MarketRewards marketRewards, ClovCommunityExecutor executor, address protocolTreasury) {
        // Step 17: MarketRewards — USDC vault that funds maker rebate claims.
        marketRewards = new MarketRewards(USDC, deployer);
        console.log("MarketRewards:", address(marketRewards));

        // Step 18: ClovCommunityExecutor — community-tier fee distribution path.
        //   2.3% taker fee pulled in USDC and split 0.6 / 1.0 / 0.7 (rebate / creator / protocol).
        protocolTreasury = vm.envOr("PROTOCOL_TREASURY_ADDRESS", deployer);
        console.log("protocolTreasury (fee destination):", protocolTreasury);

        executor = new ClovCommunityExecutor(
            USDC,
            address(ctfExchange),
            address(negRiskCtfExchange),
            address(marketFactory),
            address(negRiskCommunityRegistry),
            address(marketRewards),
            protocolTreasury
        );
        console.log("ClovCommunityExecutor:", address(executor));

        // Step 19: authorise the executor as operator on both exchanges so its
        //          matchCommunity / matchCommunityNegRisk paths can call matchOrders.
        //          Relayer EOA remains operator for curated-market flow.
        ctfExchange.addOperator(address(executor));
        console.log("CTFExchange: executor authorised as operator");
        negRiskCtfExchange.addOperator(address(executor));
        console.log("NegRiskCtfExchange: executor authorised as operator");
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
