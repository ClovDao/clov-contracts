// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { NegRiskCommunityRegistry } from "../../src/neg-risk/NegRiskCommunityRegistry.sol";
import { NegRiskOperator } from "../../src/neg-risk/NegRiskOperator.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ──────────────────────────────────────────────
// Mock ERC20
// ──────────────────────────────────────────────

contract InvariantMockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ──────────────────────────────────────────────
// Handler
// ──────────────────────────────────────────────

contract RegistryHandler is Test {
    NegRiskCommunityRegistry public registry;
    InvariantMockERC20 public usdc;
    address public operator;

    // ── Ghost state ──
    bytes32[] public ghost_marketIds;
    mapping(bytes32 => bool) public ghost_marketExists;
    mapping(bytes32 => address) public ghost_marketCreator;
    mapping(bytes32 => uint256) public ghost_originalDeposit;
    mapping(bytes32 => uint256) public ghost_challengeDeadline;
    mapping(bytes32 => uint256) public ghost_feesAccrued;
    mapping(bytes32 => uint256) public ghost_feesClaimed;
    mapping(bytes32 => uint256) public ghost_bondEscrowed;
    mapping(bytes32 => bool) public ghost_depositRefunded;

    uint256 public ghost_marketNonce;

    // Fixed actor set
    address[] public creators;
    address[] public challengers;

    uint256 public constant MAX_MARKETS = 10;

    constructor(NegRiskCommunityRegistry _registry, InvariantMockERC20 _usdc, address _operator) {
        registry = _registry;
        usdc = _usdc;
        operator = _operator;

        for (uint256 i = 0; i < 5; i++) {
            creators.push(makeAddr(string(abi.encodePacked("creator", i))));
            challengers.push(makeAddr(string(abi.encodePacked("challenger", i))));
        }
    }

    // ──────────────────────────────────────────────
    // Handler actions
    // ──────────────────────────────────────────────

    function handler_createMarket(uint256 creatorSeed) external {
        if (registry.paused()) return;
        if (ghost_marketIds.length >= MAX_MARKETS) return;

        // Pin a unique NR market id for this invocation, then push it to the operator
        // mock so the registry sees a brand-new id.
        bytes32 newId = keccak256(abi.encodePacked("inv-market", ghost_marketNonce));
        ghost_marketNonce++;

        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.prepareCommunityMarket.selector), abi.encode(newId)
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.prepareCommunityQuestion.selector),
            abi.encode(keccak256(abi.encodePacked("q", newId)))
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.clearCommunityPermissionlessAssertion.selector),
            abi.encode()
        );
        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.setCommunityPermissionlessAssertion.selector), abi.encode()
        );

        address creator = creators[creatorSeed % creators.length];
        uint256 deposit = registry.communityCreationDeposit();
        usdc.mint(creator, deposit);

        vm.startPrank(creator);
        usdc.approve(address(registry), deposit);

        NegRiskCommunityRegistry.QuestionInput[] memory qs = new NegRiskCommunityRegistry.QuestionInput[](1);
        qs[0] = NegRiskCommunityRegistry.QuestionInput({
            data: hex"deadbeef", requestId: keccak256(abi.encodePacked("req", newId))
        });
        bytes32 nrMarketId = registry.createCommunityMarket(200, hex"deadbeef", qs);
        vm.stopPrank();

        ghost_marketIds.push(nrMarketId);
        ghost_marketExists[nrMarketId] = true;
        ghost_marketCreator[nrMarketId] = creator;
        ghost_originalDeposit[nrMarketId] = deposit;
        ghost_challengeDeadline[nrMarketId] = block.timestamp + registry.CHALLENGE_PERIOD();
    }

    function handler_challenge(uint256 marketSeed, uint256 challengerSeed) external {
        if (ghost_marketIds.length == 0) return;
        bytes32 nrMarketId = ghost_marketIds[marketSeed % ghost_marketIds.length];

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        if (m.creationStatus != NegRiskCommunityRegistry.CreationStatus.Pending) return;
        if (block.timestamp > m.challengeDeadline) return;

        address challenger = challengers[challengerSeed % challengers.length];

        vm.prank(challenger);
        registry.challengeMarket(nrMarketId, keccak256(abi.encode(marketSeed, challengerSeed)));

        // Challenge bond now lives on UMA (not the registry). Ghost records presence only.
        ghost_bondEscrowed[nrMarketId] = 1;
    }

    function handler_activate(uint256 marketSeed) external {
        if (ghost_marketIds.length == 0) return;
        bytes32 nrMarketId = ghost_marketIds[marketSeed % ghost_marketIds.length];

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        if (m.creationStatus != NegRiskCommunityRegistry.CreationStatus.Pending) return;
        if (block.timestamp <= m.challengeDeadline) return;

        registry.activateMarket(nrMarketId);
    }

    function handler_accrueFee(uint256 marketSeed, uint256 amount) external {
        if (ghost_marketIds.length == 0) return;
        bytes32 nrMarketId = ghost_marketIds[marketSeed % ghost_marketIds.length];

        amount = bound(amount, 1, 1_000e6);
        address feePayer = creators[marketSeed % creators.length];
        usdc.mint(feePayer, amount);

        vm.startPrank(feePayer);
        usdc.approve(address(registry), amount);
        registry.accrueCreatorFee(nrMarketId, amount);
        vm.stopPrank();

        ghost_feesAccrued[nrMarketId] += amount;
    }

    function handler_claimFee(uint256 marketSeed) external {
        if (ghost_marketIds.length == 0) return;
        bytes32 nrMarketId = ghost_marketIds[marketSeed % ghost_marketIds.length];

        NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(nrMarketId);
        if (m.creatorFeeAccumulated == 0) return;

        uint256 claimable = m.creatorFeeAccumulated;
        address creator = ghost_marketCreator[nrMarketId];
        vm.prank(creator);
        registry.claimCreatorFee(nrMarketId);

        ghost_feesClaimed[nrMarketId] += claimable;
    }

    function handler_warpTime(uint256 secondsToWarp) external {
        secondsToWarp = bound(secondsToWarp, 1, 24 hours);
        vm.warp(block.timestamp + secondsToWarp);
    }

    function getMarketCount() external view returns (uint256) {
        return ghost_marketIds.length;
    }
}

// ──────────────────────────────────────────────
// Invariant tests
// ──────────────────────────────────────────────

contract NegRiskCommunityRegistryInvariants is StdInvariant, Test {
    NegRiskCommunityRegistry public registry;
    InvariantMockERC20 public usdc;
    RegistryHandler public handler;

    address public operator = makeAddr("operator");
    address public nrAdapter = makeAddr("nrAdapter");
    address public nrExchange = makeAddr("nrExchange");
    address public oracle = makeAddr("oracle");

    function setUp() public {
        usdc = new InvariantMockERC20();
        registry = new NegRiskCommunityRegistry(address(usdc), operator, nrAdapter, nrExchange);
        registry.setOracle(oracle);

        // Seed mocks; handler_createMarket will re-mock per invocation for unique ids.
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.prepareCommunityMarket.selector),
            abi.encode(bytes32(uint256(1)))
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.prepareCommunityQuestion.selector),
            abi.encode(bytes32(uint256(2)))
        );
        vm.mockCall(
            operator,
            abi.encodeWithSelector(NegRiskOperator.clearCommunityPermissionlessAssertion.selector),
            abi.encode()
        );
        vm.mockCall(
            operator, abi.encodeWithSelector(NegRiskOperator.setCommunityPermissionlessAssertion.selector), abi.encode()
        );
        vm.mockCall(nrAdapter, abi.encodeWithSignature("getPositionId(bytes32,bool)"), abi.encode(uint256(1)));
        vm.mockCall(nrAdapter, abi.encodeWithSignature("getConditionId(bytes32)"), abi.encode(bytes32(uint256(0xC0AD))));
        vm.mockCall(nrExchange, abi.encodeWithSignature("registerToken(uint256,uint256,bytes32)"), abi.encode());
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("assertMarketChallenge(bytes32,bytes32,address)"),
            abi.encode(bytes32(uint256(1)))
        );

        handler = new RegistryHandler(registry, usdc, operator);
        targetContract(address(handler));
    }

    /// @notice Per-market: creatorFeeAccumulated == feesAccrued - feesClaimed, and claimed never exceeds accrued.
    function invariant_creatorFeeConservation() public view {
        uint256 count = handler.getMarketCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.ghost_marketIds(i);
            NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(id);

            uint256 accrued = handler.ghost_feesAccrued(id);
            uint256 claimed = handler.ghost_feesClaimed(id);
            assertTrue(claimed <= accrued, "claimed must never exceed accrued");
            assertEq(m.creatorFeeAccumulated, accrued - claimed, "accumulator must equal accrued - claimed");
        }
    }

    /// @notice The challenge deadline, once recorded at creation, never mutates.
    function invariant_challengeDeadlineImmutable() public view {
        uint256 count = handler.getMarketCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.ghost_marketIds(i);
            NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(id);
            assertEq(m.challengeDeadline, handler.ghost_challengeDeadline(id), "challengeDeadline must not mutate");
        }
    }

    /// @notice A market in creationStatus=Active can only exist post-deadline.
    function invariant_activationRequiresDeadlinePass() public view {
        uint256 count = handler.getMarketCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.ghost_marketIds(i);
            NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(id);
            if (m.creationStatus == NegRiskCommunityRegistry.CreationStatus.Active) {
                assertTrue(block.timestamp > m.challengeDeadline, "Active requires deadline elapsed");
            }
        }
    }

    /// @notice Registry USDC balance covers all live obligations (challenger bonds live
    ///         on UMA, so they are not part of registry obligations).
    function invariant_registrySolvency() public view {
        uint256 count = handler.getMarketCount();
        uint256 obligations;
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.ghost_marketIds(i);
            NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(id);
            obligations += m.creationDeposit;
            obligations += m.creatorFeeAccumulated;
        }
        assertTrue(
            IERC20(address(usdc)).balanceOf(address(registry)) >= obligations,
            "registry USDC balance must cover all obligations"
        );
    }

    /// @notice Once a market is Challenged, it remains Challenged until the oracle callback
    ///         routes it back (no handler path transitions it directly).
    function invariant_challengedIsSticky() public view {
        uint256 count = handler.getMarketCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.ghost_marketIds(i);
            if (handler.ghost_bondEscrowed(id) == 0) continue;

            NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(id);
            assertEq(
                uint8(m.creationStatus),
                uint8(NegRiskCommunityRegistry.CreationStatus.Challenged),
                "bond escrowed implies Challenged state"
            );
        }
    }

    /// @notice The original creator is never overwritten.
    function invariant_creatorImmutable() public view {
        uint256 count = handler.getMarketCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.ghost_marketIds(i);
            NegRiskCommunityRegistry.CommunityMarket memory m = registry.getMarket(id);
            assertEq(m.creator, handler.ghost_marketCreator(id), "creator must never change");
        }
    }
}
