// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CTFExchange} from "../exchange/CTFExchange.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

/// @title NegRiskCtfExchange
/// @notice A slightly modified version of CTFExchange
/// @notice with added approvals for the NegRiskAdapter
contract NegRiskCtfExchange is CTFExchange {
    constructor(address _collateral, address _ctf, address _negRiskAdapter, address _safeFactory)
        CTFExchange(_collateral, _negRiskAdapter, _safeFactory)
    {
        IConditionalTokens(_ctf).setApprovalForAll(_negRiskAdapter, true);
        IConditionalTokens(_ctf).setApprovalForAll(address(this), true);
    }
}
