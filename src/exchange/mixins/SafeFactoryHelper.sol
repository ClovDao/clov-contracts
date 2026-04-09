// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { SafeLib } from "../libraries/SafeLib.sol";

interface ISafeFactory {
    function masterCopy() external view returns (address);
}

abstract contract SafeFactoryHelper {
    /// @notice The Gnosis Safe Factory Contract
    address public safeFactory;

    event SafeFactoryUpdated(address indexed oldSafeFactory, address indexed newSafeFactory);

    constructor(address _safeFactory) {
        safeFactory = _safeFactory;
    }

    /// @notice Gets the Safe factory address
    function getSafeFactory() public view returns (address) {
        return safeFactory;
    }

    /// @notice Gets the Safe factory implementation address
    function getSafeFactoryImplementation() public view returns (address) {
        return ISafeFactory(safeFactory).masterCopy();
    }

    /// @notice Gets the Gnosis Safe address for a signer
    /// @param _addr - The address that owns the safe
    function getSafeAddress(address _addr) public view returns (address) {
        return SafeLib.getSafeAddress(_addr, getSafeFactoryImplementation(), safeFactory);
    }

    function _setSafeFactory(address _newSafeFactory) internal {
        emit SafeFactoryUpdated(safeFactory, _newSafeFactory);
        safeFactory = _newSafeFactory;
    }
}
