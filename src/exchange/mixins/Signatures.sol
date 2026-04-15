// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { ECDSA } from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

import { SignatureType, Order } from "../libraries/OrderStructs.sol";

import { ISignatures } from "../interfaces/ISignatures.sol";

import { SafeFactoryHelper } from "./SafeFactoryHelper.sol";

interface IProxyWalletFactory {
    function getProxyAddress(address owner) external view returns (address);
}

/// @title Signatures
/// @notice Maintains logic that defines the various signature types and validates them
abstract contract Signatures is ISignatures, SafeFactoryHelper {
    /// @notice Per-user Clov Proxy Wallet factory used to recompute `maker` for POLY_PROXY signatures.
    address public immutable proxyFactory;

    constructor(address _safeFactory, address _proxyFactory) SafeFactoryHelper(_safeFactory) {
        proxyFactory = _proxyFactory;
    }

    /// @notice Validates the signature of an order
    /// @param orderHash - The hash of the order
    /// @param order     - The order
    function validateOrderSignature(bytes32 orderHash, Order memory order) public view override {
        if (!isValidSignature(order.signer, order.maker, orderHash, order.signature, order.signatureType)) {
            revert InvalidSignature();
        }
    }

    /// @notice Verifies a signature for signed Order structs
    /// @param signer           - Address of the signer
    /// @param associated       - Address associated with the signer
    /// @param structHash       - The hash of the struct being verified
    /// @param signature        - The signature to be verified
    /// @param signatureType    - The signature type to be verified
    function isValidSignature(
        address signer,
        address associated,
        bytes32 structHash,
        bytes memory signature,
        SignatureType signatureType
    ) internal view returns (bool) {
        if (signatureType == SignatureType.EOA) {
            return verifyEOASignature(signer, associated, structHash, signature);
        } else if (signatureType == SignatureType.POLY_PROXY) {
            return verifyPolyProxySignature(signer, associated, structHash, signature);
        } else if (signatureType == SignatureType.GNOSIS_SAFE) {
            return verifySafeSignature(signer, associated, structHash, signature);
        } else if (signatureType == SignatureType.ERC1271) {
            return verify1271Signature(signer, associated, structHash, signature);
        } else {
            revert InvalidSignature();
        }
    }

    /// @notice Verifies a signature produced by the EOA owner of a Clov Proxy Wallet.
    /// @dev    The `associated` address is the proxy wallet that will act as the maker. We ECDSA-recover
    ///         the signer from the order hash and then recompute the CREATE2 address of that signer's
    ///         proxy wallet; the two must match. If they do not, the order is invalid.
    /// @param signer        Address of the EOA that signed the order.
    /// @param proxyAddress  Address associated with the signer (i.e. the Proxy Wallet acting as maker).
    /// @param structHash    Hash of the order struct being verified.
    /// @param signature     The ECDSA signature to verify.
    function verifyPolyProxySignature(address signer, address proxyAddress, bytes32 structHash, bytes memory signature)
        internal
        view
        returns (bool)
    {
        return verifyECDSASignature(signer, structHash, signature)
            && IProxyWalletFactory(proxyFactory).getProxyAddress(signer) == proxyAddress;
    }

    /// @notice Verifies an EOA ECDSA signature
    /// @param signer      - The address of the signer
    /// @param maker       - The address of the maker
    /// @param structHash  - The hash of the struct being verified
    /// @param signature   - The signature to be verified
    function verifyEOASignature(address signer, address maker, bytes32 structHash, bytes memory signature)
        internal
        pure
        returns (bool)
    {
        return (signer == maker) && verifyECDSASignature(signer, structHash, signature);
    }

    /// @notice Verifies an ECDSA signature
    /// @param signer      - Address of the signer
    /// @param structHash  - The hash of the struct being verified
    /// @param signature   - The signature to be verified
    function verifyECDSASignature(address signer, bytes32 structHash, bytes memory signature)
        internal
        pure
        returns (bool)
    {
        return ECDSA.recover(structHash, signature) == signer;
    }

    /// @notice Verifies a signature signed by a Gnosis Safe
    /// @param signer      - Address of the signer
    /// @param safeAddress - Address of the safe
    /// @param hash        - Hash of the struct being verified
    /// @param signature   - Signature to be verified
    function verifySafeSignature(address signer, address safeAddress, bytes32 hash, bytes memory signature)
        internal
        view
        returns (bool)
    {
        return verifyECDSASignature(signer, hash, signature) && getSafeAddress(signer) == safeAddress;
    }

    /// @notice Verifies a signature signed by a smart contract (ERC-1271)
    /// @param signer           - Address of the smart contract
    /// @param maker            - Address of the smart contract
    /// @param hash             - Hash of the struct being verified
    /// @param signature        - Signature to be verified
    function verify1271Signature(address signer, address maker, bytes32 hash, bytes memory signature)
        internal
        view
        returns (bool)
    {
        return (signer == maker) && maker.code.length > 0
            && SignatureCheckerLib.isValidSignatureNow(maker, hash, signature);
    }
}
