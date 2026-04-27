// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ProxyWalletImplementation
/// @notice Per-user Clov Proxy Wallet. Acts as the CLOB `maker`, holds USDC + CTF outcome shares,
///         and forwards arbitrary calls on behalf of its owner EOA.
/// @dev    Deployed once as an implementation contract. Each user owns an EIP-1167 minimal-proxy
///         clone created via {ProxyWalletFactory} with salt `keccak256(abi.encode(owner))`.
///         The owner is stored in the clone's own storage (slot 0) via {initialize} — NOT via
///         delegatecall to this contract's storage.
contract ProxyWalletImplementation is IERC1155Receiver {
    using SafeERC20 for IERC20;

    /// @notice EOA owner of this proxy wallet. Set once in {initialize}.
    address public owner;

    event Initialized(address indexed owner);
    event Executed(address indexed target, uint256 value, bytes data, bytes result);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Approved(address indexed token, address indexed spender, uint256 amount);
    event ApprovedForAll(address indexed token, address indexed operator, bool approved);

    error AlreadyInitialized();
    error NotOwner();
    error ZeroOwner();
    error ZeroAddress();
    error ExecutionFailed(bytes returnData);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Disable the implementation so the logic contract itself can never be initialized.
    constructor() {
        owner = address(0xdead);
    }

    /// @notice Initialize a freshly deployed clone. Called exactly once by the factory.
    /// @param _owner The EOA that owns this proxy wallet.
    function initialize(address _owner) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (_owner == address(0)) revert ZeroOwner();
        owner = _owner;
        emit Initialized(_owner);
    }

    /// @notice Forward an arbitrary call from this proxy wallet. Only callable by the owner EOA.
    /// @dev    Used for on-chain cancellation (`execute(exchange, incrementNonce)`) and any future
    ///         owner-authorized actions (approvals, redemptions, etc.).
    /// @param target The destination contract.
    /// @param data   The calldata to forward.
    /// @return result The raw return data of the call.
    function execute(address target, bytes calldata data) external payable onlyOwner returns (bytes memory result) {
        if (target == address(0)) revert ZeroAddress();
        bool success;
        (success, result) = target.call{ value: msg.value }(data);
        if (!success) revert ExecutionFailed(result);
        emit Executed(target, msg.value, data, result);
    }

    /// @notice Withdraw ERC20 funds held by the proxy. Only callable by the owner EOA.
    /// @param token  The ERC20 token address.
    /// @param to     The recipient address.
    /// @param amount The amount to transfer.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Withdraw ERC1155 outcome shares held by the proxy. Only callable by the owner EOA.
    /// @param token   The ERC1155 token contract (CTF).
    /// @param to      The recipient address.
    /// @param tokenId The ERC1155 token id.
    /// @param amount  The amount to transfer.
    function withdrawERC1155(address token, address to, uint256 tokenId, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        emit Withdrawn(token, to, amount);
    }

    /// @notice Set an ERC20 allowance for a spender (typically the CTFExchange).
    /// @param token   The ERC20 token.
    /// @param spender The approved spender.
    /// @param amount  The allowance.
    function approveERC20(address token, address spender, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();
        IERC20(token).forceApprove(spender, amount);
        emit Approved(token, spender, amount);
    }

    /// @notice Set an ERC1155 operator approval (typically the CTFExchange).
    /// @param token    The ERC1155 token contract.
    /// @param operator The operator being approved.
    /// @param approved True to approve, false to revoke.
    function setApprovalForAll(address token, address operator, bool approved) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (operator == address(0)) revert ZeroAddress();
        IERC1155(token).setApprovalForAll(operator, approved);
        emit ApprovedForAll(token, operator, approved);
    }

    /// @notice Accept ETH transfers (e.g. refunds). Owner can always sweep via {execute}.
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////
                            ERC1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
