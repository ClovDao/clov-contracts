// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

import { ProxyWalletImplementation } from "../src/ProxyWalletImplementation.sol";
import { ProxyWalletFactory } from "../src/ProxyWalletFactory.sol";

/// @title DeployProxyWallet
/// @notice Standalone deploy script for the Clov Proxy Wallet implementation and factory.
/// @dev    Use on Amoy when the CTFExchange is already deployed and only the proxy
///         contracts need to be added. For fresh deploys use {Deploy.s.sol} instead.
/// @dev    Usage: forge script script/DeployProxyWallet.s.sol --rpc-url amoy --broadcast
contract DeployProxyWallet is Script {
    function run() external returns (address implementation, address factory) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        ProxyWalletImplementation impl = new ProxyWalletImplementation();
        console.log("ProxyWalletImplementation:", address(impl));

        ProxyWalletFactory fac = new ProxyWalletFactory(address(impl));
        console.log("ProxyWalletFactory:", address(fac));

        vm.stopBroadcast();

        return (address(impl), address(fac));
    }
}
