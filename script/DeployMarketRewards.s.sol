// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { MarketRewards } from "../src/MarketRewards.sol";
/// @title DeployMarketRewards — deploy MarketRewards to Polygon Amoy
/// @dev Usage: forge script script/DeployMarketRewards.s.sol --rpc-url amoy --broadcast --verify
contract DeployMarketRewards is Script {
    address constant USDC = 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582;

    function run() external {
        require(block.chainid == 80002, "TESTNET ONLY: Amoy chain ID required");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== MarketRewards Deployment ===");
        console.log("Deployer:", deployer);
        console.log("USDC:", USDC);

        vm.startBroadcast(deployerPrivateKey);

        MarketRewards rewards = new MarketRewards(USDC, deployer);
        console.log("MarketRewards:", address(rewards));

        vm.stopBroadcast();

        console.log("=== Done - update CONTRACT_ADDRESSES.marketRewards ===");
    }
}
