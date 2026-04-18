// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { MarketFactory } from "../src/MarketFactory.sol";

/// @title UpdateCreationDeposit — lower (or change) the MarketFactory creation deposit on a live chain
/// @notice Calls MarketFactory.updateCreationDeposit(newDeposit). Must be executed by the contract owner.
///         newDeposit is read from the NEW_DEPOSIT env var (in token base units, e.g. 1_000_000 == 1 USDC).
///         The target factory is read from the MARKET_FACTORY env var.
/// @dev Usage:
///      MARKET_FACTORY=0xa989a108e027ef475555968466d8bE7d01b63f3b \
///      NEW_DEPOSIT=1000000 \
///      forge script script/UpdateCreationDeposit.s.sol --rpc-url amoy --broadcast
contract UpdateCreationDeposit is Script {
    function run() external {
        require(block.chainid == 80002, "TESTNET ONLY: Amoy chain ID required");

        address factoryAddress = vm.envAddress("MARKET_FACTORY");
        uint256 newDeposit = vm.envUint("NEW_DEPOSIT");

        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(ownerPrivateKey);

        MarketFactory factory = MarketFactory(factoryAddress);
        uint256 previous = factory.creationDeposit();
        address owner = factory.owner();

        console.log("=== Update MarketFactory.creationDeposit ===");
        console.log("Factory:", factoryAddress);
        console.log("Owner (on-chain):", owner);
        console.log("Sender:", sender);
        console.log("Previous deposit:", previous);
        console.log("New deposit:", newDeposit);

        require(sender == owner, "Sender is not the factory owner");

        vm.startBroadcast(ownerPrivateKey);
        factory.updateCreationDeposit(newDeposit);
        vm.stopBroadcast();

        uint256 current = factory.creationDeposit();
        require(current == newDeposit, "Post-update deposit mismatch");
        console.log("=== Done. creationDeposit now:", current);
    }
}
