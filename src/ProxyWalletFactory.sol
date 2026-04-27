// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ProxyWalletImplementation } from "./ProxyWalletImplementation.sol";

/// @title ProxyWalletFactory
/// @notice Deploys per-user Clov Proxy Wallets as EIP-1167 minimal-proxy clones using CREATE2.
/// @dev    Salt is `keccak256(abi.encode(owner))` — one proxy per EOA, address is deterministic
///         and counterfactually computable before deployment.
contract ProxyWalletFactory {
    /// @notice Shared logic contract that every user's clone delegates to.
    address public immutable implementation;

    event ProxyDeployed(address indexed owner, address indexed proxy);

    error ZeroOwner();
    error ZeroImplementation();

    constructor(address _implementation) {
        if (_implementation == address(0)) revert ZeroImplementation();
        implementation = _implementation;
    }

    /// @notice Returns the deterministic CREATE2 address of the proxy wallet for a given owner,
    ///         whether or not it has been deployed yet.
    /// @param owner The EOA whose proxy address to compute.
    function getProxyAddress(address owner) external view returns (address) {
        return _predict(owner);
    }

    /// @notice Returns true if a proxy has already been deployed for the given owner.
    /// @param owner The EOA to check.
    function isDeployed(address owner) external view returns (bool) {
        return _predict(owner).code.length > 0;
    }

    /// @notice Deploy the proxy wallet for `owner`. Idempotent: returns the existing address if
    ///         already deployed, otherwise creates the clone and initializes it.
    /// @param owner The EOA that will own the new proxy.
    /// @return proxy The address of the (now) deployed proxy wallet.
    function deployProxy(address owner) external returns (address proxy) {
        if (owner == address(0)) revert ZeroOwner();

        address predicted = _predict(owner);
        if (predicted.code.length > 0) {
            // Already deployed — idempotent: return the existing address without reverting.
            return predicted;
        }

        proxy = Clones.cloneDeterministic(implementation, _salt(owner));
        ProxyWalletImplementation(payable(proxy)).initialize(owner);
        emit ProxyDeployed(owner, proxy);
    }

    /// @notice CREATE2 salt for an owner. Exposed for off-chain parity with the backend derivation.
    function computeSalt(address owner) external pure returns (bytes32) {
        return _salt(owner);
    }

    function _salt(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner));
    }

    function _predict(address owner) internal view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner), address(this));
    }
}
