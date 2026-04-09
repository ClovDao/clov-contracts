// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { ECDSA } from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

import { SignatureType, Order } from "../libraries/OrderStructs.sol";

import { ISignatures } from "../interfaces/ISignatures.sol";

import { SafeFactoryHelper } from "./SafeFactoryHelper.sol";

/// @title Signatures
/// @notice Maintains logic that defines the various signature types and validates them
abstract contract Signatures is ISignatures, SafeFactoryHelper {
    constructor(address _safeFactory) SafeFactoryHelper(_safeFactory) { }

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
        } else if (signatureType == SignatureType.GNOSIS_SAFE) {
            return verifySafeSignature(signer, associated, structHash, signature);
        } else if (signatureType == SignatureType.ERC1271) {
            return verify1271Signature(signer, associated, structHash, signature);
        } else {
            revert InvalidSignature();
        }
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
