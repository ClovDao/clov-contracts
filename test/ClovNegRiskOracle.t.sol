// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ClovNegRiskOracle } from "../src/neg-risk/ClovNegRiskOracle.sol";
import { IOptimisticOracleV3 } from "../src/interfaces/IOptimisticOracleV3.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ClovNegRiskOracleTest is Test {
    ClovNegRiskOracle public oracle;
    MockERC20 public bondToken;

    address public owner;
    address public umaOracle = makeAddr("umaOracle");
    address public negRiskOperator = makeAddr("negRiskOperator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant BOND_AMOUNT = 500e6;
    uint256 public constant CHALLENGE_BOND_AMOUNT = 500e6;
    uint64 public constant ASSERTION_LIVENESS = 7200;
    bytes32 public constant DEFAULT_IDENTIFIER = keccak256("ASSERT_TRUTH");
    bytes32 public constant REQUEST_ID = keccak256("req-1");

    function setUp() public {
        owner = address(this);
        bondToken = new MockERC20();

        vm.mockCall(
            umaOracle,
            abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector),
            abi.encode(DEFAULT_IDENTIFIER)
        );

        oracle = new ClovNegRiskOracle(
            umaOracle, address(bondToken), negRiskOperator, BOND_AMOUNT, CHALLENGE_BOND_AMOUNT, ASSERTION_LIVENESS
        );
    }

    // ──────────────────────────────────────────────
    // setPermissionlessAssertion — access control
    // ──────────────────────────────────────────────

    function test_setPermissionlessAssertion_onlyNegRiskOperator() public {
        vm.prank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);
        assertTrue(oracle.isPermissionlessAssertion(REQUEST_ID));
    }

    function test_setPermissionlessAssertion_revertsForNonOperator() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClovNegRiskOracle.OnlyNegRiskOperator.selector, alice));
        oracle.setPermissionlessAssertion(REQUEST_ID);
    }

    function test_setPermissionlessAssertion_revertsForOwner() public {
        // owner is NOT the negRiskOperator — must still be rejected
        vm.expectRevert(abi.encodeWithSelector(ClovNegRiskOracle.OnlyNegRiskOperator.selector, owner));
        oracle.setPermissionlessAssertion(REQUEST_ID);
    }

    function test_setPermissionlessAssertion_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ClovNegRiskOracle.PermissionlessAssertionSet(REQUEST_ID);

        vm.prank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);
    }

    // ──────────────────────────────────────────────
    // clearPermissionlessAssertion — access control
    // ──────────────────────────────────────────────

    function test_clearPermissionlessAssertion_onlyNegRiskOperator() public {
        vm.startPrank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);
        oracle.clearPermissionlessAssertion(REQUEST_ID);
        vm.stopPrank();

        assertFalse(oracle.isPermissionlessAssertion(REQUEST_ID));
    }

    function test_clearPermissionlessAssertion_revertsForNonOperator() public {
        vm.prank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClovNegRiskOracle.OnlyNegRiskOperator.selector, alice));
        oracle.clearPermissionlessAssertion(REQUEST_ID);
    }

    function test_clearPermissionlessAssertion_emitsEvent() public {
        vm.prank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);

        vm.expectEmit(true, false, false, false);
        emit ClovNegRiskOracle.PermissionlessAssertionCleared(REQUEST_ID);

        vm.prank(negRiskOperator);
        oracle.clearPermissionlessAssertion(REQUEST_ID);
    }

    // ──────────────────────────────────────────────
    // isPermissionlessAssertion — default + idempotent
    // ──────────────────────────────────────────────

    function test_isPermissionlessAssertion_defaultsFalse() public view {
        assertFalse(oracle.isPermissionlessAssertion(REQUEST_ID));
    }

    function test_isPermissionlessAssertion_isolatedPerRequest() public {
        bytes32 other = keccak256("req-2");

        vm.prank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);

        assertTrue(oracle.isPermissionlessAssertion(REQUEST_ID));
        assertFalse(oracle.isPermissionlessAssertion(other));
    }

    // ──────────────────────────────────────────────
    // assertOutcome — flag bypasses allowedAsserters
    // ──────────────────────────────────────────────

    function test_assertOutcome_permissionless_bypassesAllowlist() public {
        vm.prank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(oracle), BOND_AMOUNT);

        bytes32 expectedAssertId = keccak256("mock-assertion-id");
        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(expectedAssertId)
        );

        vm.prank(bob); // bob is NOT allowlisted
        bytes32 assertionId = oracle.assertOutcome(REQUEST_ID, true, alice);

        assertEq(assertionId, expectedAssertId);
        assertEq(oracle.requestToAssertion(REQUEST_ID), expectedAssertId);
    }

    function test_assertOutcome_withoutFlag_revertsForNonAllowlisted() public {
        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(oracle), BOND_AMOUNT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ClovNegRiskOracle.UnauthorizedAsserter.selector, bob));
        oracle.assertOutcome(REQUEST_ID, true, alice);
    }

    function test_assertOutcome_cleared_revertsAgain() public {
        vm.startPrank(negRiskOperator);
        oracle.setPermissionlessAssertion(REQUEST_ID);
        oracle.clearPermissionlessAssertion(REQUEST_ID);
        vm.stopPrank();

        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(oracle), BOND_AMOUNT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ClovNegRiskOracle.UnauthorizedAsserter.selector, bob));
        oracle.assertOutcome(REQUEST_ID, true, alice);
    }

    function test_assertOutcome_allowlistedStillWorksWhenFlagUnset() public {
        // owner is allowlisted by default (constructor)
        bondToken.mint(alice, BOND_AMOUNT);
        vm.prank(alice);
        bondToken.approve(address(oracle), BOND_AMOUNT);

        bytes32 expectedAssertId = keccak256("mock-assertion-id");
        vm.mockCall(
            umaOracle, abi.encodeWithSelector(IOptimisticOracleV3.assertTruth.selector), abi.encode(expectedAssertId)
        );

        bytes32 assertionId = oracle.assertOutcome(REQUEST_ID, true, alice);
        assertEq(assertionId, expectedAssertId);
    }
}
