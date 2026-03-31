// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
}

contract ConditionalTokensTest is Test {
    IConditionalTokens public ct;

    address public oracle = makeAddr("oracle");
    bytes32 public questionId = keccak256("Will Argentina win Copa America 2026?");

    function setUp() public {
        // Read the compiled bytecode from the artifact JSON
        string memory artifact = vm.readFile("out/ConditionalTokens.sol/ConditionalTokens.json");
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode.object");

        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "Deploy failed");
        ct = IConditionalTokens(deployed);
    }

    function test_prepareCondition() public {
        uint256 outcomeSlotCount = 2;

        ct.prepareCondition(oracle, questionId, outcomeSlotCount);

        bytes32 conditionId = ct.getConditionId(oracle, questionId, outcomeSlotCount);
        uint256 slots = ct.getOutcomeSlotCount(conditionId);
        assertEq(slots, outcomeSlotCount, "Condition should have 2 outcome slots");
    }

    function test_prepareCondition_revertsDuplicate() public {
        ct.prepareCondition(oracle, questionId, 2);

        vm.expectRevert();
        ct.prepareCondition(oracle, questionId, 2);
    }
}
