// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import { ProxyWalletImplementation } from "../src/ProxyWalletImplementation.sol";
import { ProxyWalletFactory } from "../src/ProxyWalletFactory.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCTF is ERC1155 {
    constructor() ERC1155("") { }

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev Dummy target used to exercise {ProxyWalletImplementation.execute}.
contract ExecuteTarget {
    uint256 public pinged;
    address public lastCaller;

    event Ping(address caller, uint256 value, uint256 arg);

    function ping(uint256 arg) external payable returns (uint256) {
        pinged += arg;
        lastCaller = msg.sender;
        emit Ping(msg.sender, msg.value, arg);
        return pinged;
    }

    function boom() external pure {
        revert("boom");
    }
}

contract ProxyWalletTest is Test {
    ProxyWalletImplementation internal implementation;
    ProxyWalletFactory internal factory;
    MockUSDC internal usdc;
    MockCTF internal ctf;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    event ProxyDeployed(address indexed owner, address indexed proxy);
    event Initialized(address indexed owner);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        implementation = new ProxyWalletImplementation();
        factory = new ProxyWalletFactory(address(implementation));
        usdc = new MockUSDC();
        ctf = new MockCTF();
    }

    /*//////////////////////////////////////////////////////////////
                        FACTORY DETERMINISM
    //////////////////////////////////////////////////////////////*/

    function test_getProxyAddress_isDeterministic() public view {
        address predicted1 = factory.getProxyAddress(alice);
        address predicted2 = factory.getProxyAddress(alice);
        assertEq(predicted1, predicted2);
        assertTrue(predicted1 != address(0));
    }

    function test_getProxyAddress_differsPerOwner() public view {
        assertTrue(factory.getProxyAddress(alice) != factory.getProxyAddress(bob));
    }

    function test_getProxyAddress_matchesClonesLibrary() public view {
        bytes32 salt = factory.computeSalt(alice);
        address expected = Clones.predictDeterministicAddress(address(implementation), salt, address(factory));
        assertEq(factory.getProxyAddress(alice), expected);
    }

    function test_deployProxy_matchesCounterfactual() public {
        address predicted = factory.getProxyAddress(alice);
        assertFalse(factory.isDeployed(alice));

        vm.expectEmit(true, true, false, false);
        emit ProxyDeployed(alice, predicted);
        address deployed = factory.deployProxy(alice);

        assertEq(deployed, predicted);
        assertTrue(factory.isDeployed(alice));
    }

    function test_deployProxy_isIdempotent() public {
        address first = factory.deployProxy(alice);
        address second = factory.deployProxy(alice);
        assertEq(first, second);
    }

    function test_deployProxy_rejectsZeroOwner() public {
        vm.expectRevert(ProxyWalletFactory.ZeroOwner.selector);
        factory.deployProxy(address(0));
    }

    function test_factoryConstructor_rejectsZeroImplementation() public {
        vm.expectRevert(ProxyWalletFactory.ZeroImplementation.selector);
        new ProxyWalletFactory(address(0));
    }

    function test_deployProxy_initializesOwner() public {
        address proxyAddr = factory.deployProxy(alice);
        assertEq(ProxyWalletImplementation(payable(proxyAddr)).owner(), alice);
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsOwnerOnce() public {
        address proxyAddr = factory.deployProxy(alice);
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(proxyAddr));

        vm.expectRevert(ProxyWalletImplementation.AlreadyInitialized.selector);
        proxy.initialize(bob);
    }

    function test_initialize_rejectsZeroOwner() public {
        // Manually clone so we can attempt to (mis-)initialize with zero.
        address clone = Clones.clone(address(implementation));
        vm.expectRevert(ProxyWalletImplementation.ZeroOwner.selector);
        ProxyWalletImplementation(payable(clone)).initialize(address(0));
    }

    function test_implementationContract_cannotBeInitialized() public {
        // Implementation owner is 0xdead — must reject any re-initialization.
        vm.expectRevert(ProxyWalletImplementation.AlreadyInitialized.selector);
        implementation.initialize(alice);
        assertEq(implementation.owner(), address(0xdead));
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_onlyOwner() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        usdc.mint(address(proxy), 10e6);

        vm.prank(mallory);
        vm.expectRevert(ProxyWalletImplementation.NotOwner.selector);
        proxy.withdraw(address(usdc), mallory, 10e6);
    }

    function test_withdraw_transfersToOwner() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        usdc.mint(address(proxy), 10e6);

        vm.prank(alice);
        proxy.withdraw(address(usdc), alice, 10e6);

        assertEq(usdc.balanceOf(address(proxy)), 0);
        assertEq(usdc.balanceOf(alice), 10e6);
    }

    function test_withdraw_rejectsZeroToken() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        vm.prank(alice);
        vm.expectRevert(ProxyWalletImplementation.ZeroAddress.selector);
        proxy.withdraw(address(0), alice, 0);
    }

    function test_withdraw_rejectsZeroRecipient() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        vm.prank(alice);
        vm.expectRevert(ProxyWalletImplementation.ZeroAddress.selector);
        proxy.withdraw(address(usdc), address(0), 0);
    }

    function test_withdrawERC1155_onlyOwner_andTransfers() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        ctf.mint(address(proxy), 1, 100);

        vm.prank(mallory);
        vm.expectRevert(ProxyWalletImplementation.NotOwner.selector);
        proxy.withdrawERC1155(address(ctf), mallory, 1, 100);

        vm.prank(alice);
        proxy.withdrawERC1155(address(ctf), alice, 1, 100);
        assertEq(ctf.balanceOf(address(proxy), 1), 0);
        assertEq(ctf.balanceOf(alice, 1), 100);
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTE
    //////////////////////////////////////////////////////////////*/

    function test_execute_onlyOwner() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        ExecuteTarget target = new ExecuteTarget();
        bytes memory data = abi.encodeCall(ExecuteTarget.ping, (7));

        vm.prank(mallory);
        vm.expectRevert(ProxyWalletImplementation.NotOwner.selector);
        proxy.execute(address(target), data);
    }

    function test_execute_forwardsCallAsProxy() public {
        address proxyAddr = factory.deployProxy(alice);
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(proxyAddr));
        ExecuteTarget target = new ExecuteTarget();

        vm.prank(alice);
        bytes memory result = proxy.execute(address(target), abi.encodeCall(ExecuteTarget.ping, (42)));

        assertEq(abi.decode(result, (uint256)), 42);
        assertEq(target.pinged(), 42);
        // target sees the proxy as the caller — critical for nonce-increment cancellation.
        assertEq(target.lastCaller(), proxyAddr);
    }

    function test_execute_bubblesRevert() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        ExecuteTarget target = new ExecuteTarget();

        vm.prank(alice);
        vm.expectRevert();
        proxy.execute(address(target), abi.encodeCall(ExecuteTarget.boom, ()));
    }

    function test_execute_forwardsValue() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        ExecuteTarget target = new ExecuteTarget();
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        proxy.execute{ value: 0.5 ether }(address(target), abi.encodeCall(ExecuteTarget.ping, (1)));

        assertEq(address(target).balance, 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              APPROVALS
    //////////////////////////////////////////////////////////////*/

    function test_approveERC20_onlyOwner() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));

        vm.prank(mallory);
        vm.expectRevert(ProxyWalletImplementation.NotOwner.selector);
        proxy.approveERC20(address(usdc), bob, type(uint256).max);
    }

    function test_approveERC20_setsAllowance() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        vm.prank(alice);
        proxy.approveERC20(address(usdc), bob, 1000);
        assertEq(usdc.allowance(address(proxy), bob), 1000);
    }

    function test_setApprovalForAll_onlyOwner_andSets() public {
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));

        vm.prank(mallory);
        vm.expectRevert(ProxyWalletImplementation.NotOwner.selector);
        proxy.setApprovalForAll(address(ctf), bob, true);

        vm.prank(alice);
        proxy.setApprovalForAll(address(ctf), bob, true);
        assertTrue(ctf.isApprovedForAll(address(proxy), bob));
    }

    /*//////////////////////////////////////////////////////////////
                          ERC1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function test_supportsInterface_ERC1155Receiver() public {
        address proxyAddr = factory.deployProxy(alice);
        assertTrue(ProxyWalletImplementation(payable(proxyAddr)).supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_receivesERC1155_withoutRevert() public {
        address proxyAddr = factory.deployProxy(alice);
        ctf.mint(address(this), 1, 10);
        ctf.safeTransferFrom(address(this), proxyAddr, 1, 10, "");
        assertEq(ctf.balanceOf(proxyAddr, 1), 10);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_getProxyAddress_deterministic(address owner1, address owner2) public view {
        vm.assume(owner1 != address(0));
        vm.assume(owner2 != address(0));
        address a = factory.getProxyAddress(owner1);
        address b = factory.getProxyAddress(owner1);
        assertEq(a, b);
        if (owner1 != owner2) {
            assertTrue(factory.getProxyAddress(owner2) != a);
        }
    }

    function testFuzz_deployProxy_matchesPrediction(address owner) public {
        vm.assume(owner != address(0));
        address predicted = factory.getProxyAddress(owner);
        address deployed = factory.deployProxy(owner);
        assertEq(deployed, predicted);
        assertEq(ProxyWalletImplementation(payable(deployed)).owner(), owner);
    }

    function testFuzz_withdraw_onlyOwner(address caller, uint128 amount) public {
        vm.assume(caller != alice);
        vm.assume(caller != address(0));
        ProxyWalletImplementation proxy = ProxyWalletImplementation(payable(factory.deployProxy(alice)));
        usdc.mint(address(proxy), amount);

        vm.prank(caller);
        vm.expectRevert(ProxyWalletImplementation.NotOwner.selector);
        proxy.withdraw(address(usdc), caller, amount);
    }
}
