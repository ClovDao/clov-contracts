// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { Signatures } from "../src/exchange/mixins/Signatures.sol";
import { SignatureType, Order, Side } from "../src/exchange/libraries/OrderStructs.sol";
import { ISignatures } from "../src/exchange/interfaces/ISignatures.sol";

import { ProxyWalletImplementation } from "../src/ProxyWalletImplementation.sol";
import { ProxyWalletFactory } from "../src/ProxyWalletFactory.sol";

/// @dev Exposes the internal isValidSignature path of the Signatures mixin for test harnessing.
///      SafeFactory is left zero (GNOSIS_SAFE branch is not exercised here); proxyFactory is the
///      real deployed ProxyWalletFactory.
contract SignaturesHarness is Signatures {
    constructor(address _safeFactory, address _proxyFactory) Signatures(_safeFactory, _proxyFactory) { }

    function exposed_isValidSignature(
        address signer,
        address associated,
        bytes32 structHash,
        bytes memory signature,
        SignatureType signatureType
    ) external view returns (bool) {
        // Manually dispatch the POLY_PROXY branch (and EOA, as a sanity baseline).
        if (signatureType == SignatureType.POLY_PROXY) {
            return verifyPolyProxySignature(signer, associated, structHash, signature);
        }
        if (signatureType == SignatureType.EOA) {
            return verifyEOASignature(signer, associated, structHash, signature);
        }
        revert InvalidSignature();
    }
}

contract ProxyWalletSignatureFuzzTest is Test {
    ProxyWalletImplementation internal implementation;
    ProxyWalletFactory internal factory;
    SignaturesHarness internal sigs;

    function setUp() public {
        implementation = new ProxyWalletImplementation();
        factory = new ProxyWalletFactory(address(implementation));
        sigs = new SignaturesHarness(address(0), address(factory));
    }

    /*//////////////////////////////////////////////////////////////
                           STATIC TEST CASES
    //////////////////////////////////////////////////////////////*/

    function test_polyProxy_validSignature() public {
        (address eoa, uint256 pk) = makeAddrAndKey("trader");
        bytes32 h = keccak256("order-hash-1");
        bytes memory sig = _sign(pk, h);
        address proxy = factory.getProxyAddress(eoa);

        assertTrue(sigs.exposed_isValidSignature(eoa, proxy, h, sig, SignatureType.POLY_PROXY));
    }

    function test_polyProxy_worksBeforeDeploy() public {
        // Counterfactual: proxy not yet deployed, signature still verifies.
        (address eoa, uint256 pk) = makeAddrAndKey("trader2");
        bytes32 h = keccak256("order-hash-2");
        bytes memory sig = _sign(pk, h);
        address proxy = factory.getProxyAddress(eoa);

        assertFalse(factory.isDeployed(eoa));
        assertTrue(sigs.exposed_isValidSignature(eoa, proxy, h, sig, SignatureType.POLY_PROXY));
    }

    function test_polyProxy_rejectsMismatchedMaker() public {
        (address eoa, uint256 pk) = makeAddrAndKey("trader3");
        (address other,) = makeAddrAndKey("other");
        bytes32 h = keccak256("order-hash-3");
        bytes memory sig = _sign(pk, h);
        address wrongProxy = factory.getProxyAddress(other); // different owner's proxy

        assertFalse(sigs.exposed_isValidSignature(eoa, wrongProxy, h, sig, SignatureType.POLY_PROXY));
    }

    function test_polyProxy_rejectsForgedSignature() public {
        (address eoa,) = makeAddrAndKey("trader4");
        (, uint256 otherPk) = makeAddrAndKey("impostor");
        bytes32 h = keccak256("order-hash-4");
        bytes memory sig = _sign(otherPk, h); // signed by someone else
        address proxy = factory.getProxyAddress(eoa);

        assertFalse(sigs.exposed_isValidSignature(eoa, proxy, h, sig, SignatureType.POLY_PROXY));
    }

    function test_polyProxy_rejectsWrongHash() public {
        (address eoa, uint256 pk) = makeAddrAndKey("trader5");
        bytes32 h = keccak256("order-hash-5");
        bytes32 wrongHash = keccak256("other-hash");
        bytes memory sig = _sign(pk, h);
        address proxy = factory.getProxyAddress(eoa);

        assertFalse(sigs.exposed_isValidSignature(eoa, proxy, wrongHash, sig, SignatureType.POLY_PROXY));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_polyProxy_validSignature(uint256 pk, bytes32 structHash) public view {
        pk = _boundPk(pk);
        address eoa = vm.addr(pk);
        bytes memory sig = _sign(pk, structHash);
        address proxy = factory.getProxyAddress(eoa);

        assertTrue(sigs.exposed_isValidSignature(eoa, proxy, structHash, sig, SignatureType.POLY_PROXY));
    }

    function testFuzz_polyProxy_rejectsMismatchedMaker(uint256 pk, address fakeMaker, bytes32 structHash) public view {
        pk = _boundPk(pk);
        address eoa = vm.addr(pk);
        address realProxy = factory.getProxyAddress(eoa);
        vm.assume(fakeMaker != realProxy);

        bytes memory sig = _sign(pk, structHash);
        assertFalse(sigs.exposed_isValidSignature(eoa, fakeMaker, structHash, sig, SignatureType.POLY_PROXY));
    }

    function testFuzz_polyProxy_rejectsForgedSigner(uint256 realPk, uint256 forgerPk, bytes32 structHash) public view {
        realPk = _boundPk(realPk);
        forgerPk = _boundPk(forgerPk);
        vm.assume(realPk != forgerPk);

        address eoa = vm.addr(realPk);
        bytes memory forgedSig = _sign(forgerPk, structHash);
        address proxy = factory.getProxyAddress(eoa);

        // We claim `eoa` is the signer, but the signature was actually produced by forgerPk.
        // ECDSA.recover returns the forger; it won't equal `eoa`, so verification fails.
        assertFalse(sigs.exposed_isValidSignature(eoa, proxy, structHash, forgedSig, SignatureType.POLY_PROXY));
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _sign(uint256 pk, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Bound a fuzzed uint into the valid secp256k1 private-key range.
    function _boundPk(uint256 pk) internal pure returns (uint256) {
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141; // secp256k1 n
        return (pk % (n - 1)) + 1;
    }
}
