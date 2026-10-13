// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {YFDToken} from "../src/YFDToken.sol";

/// @notice Stands in for the launch factory: deploys the token and performs the launch flows
/// (distributor share, pool seed, remainder) from the address the constructor minted to. Deploying
/// through a contract, in one call, mirrors `ProjectFactory.launchCustom`, which deploys and moves
/// the supply inside a single transaction.
contract FactoryProbe {
    YFDToken public token;
    uint256 public supplyAfterConstructor;
    uint256 public heldAfterConstructor;

    /// @dev Deploys the token and records what the constructor left, all in one transaction.
    function launch() external returns (YFDToken deployed) {
        deployed = new YFDToken();
        token = deployed;
        supplyAfterConstructor = deployed.totalSupply();
        heldAfterConstructor = deployed.balanceOf(address(this));
    }

    function move(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return token.approve(spender, amount);
    }
}

/// @notice An ERC-20 flow exactly as the Uniswap v4 PoolManager performs it: `transferFrom` out of the
/// seeder under an allowance, then a plain `transfer` back to a trader.
contract PoolManagerProbe {
    function pull(IERC20 token, address from, uint256 amount) external returns (bool) {
        return token.transferFrom(from, address(this), amount);
    }

    function push(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Failure paths and edges of the Yield Fields Deed token: zero, one wei, the whole supply,
/// one over it, the same call twice, callers the implementation did not expect, and every launch flow
/// the factory performs, each checked for the exact amount it states.
/// forge-config: default.fuzz.runs = 1000
contract YFDTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant RUNTIME_LIMIT = 24_576;

    FactoryProbe factory;
    YFDToken token;

    address distributor = makeAddr("distributor");
    address claimant = makeAddr("claimant");
    address requester = makeAddr("requester");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        factory = new FactoryProbe();
        token = factory.launch();
    }

    // ───────────────────────────── constructor ─────────────────────────────

    function test_constructorMintsOnceToDeployerInsideOneTransaction() public view {
        assertEq(factory.supplyAfterConstructor(), SUPPLY, "supply after constructor");
        assertEq(factory.heldAfterConstructor(), SUPPLY, "deployer balance after constructor");
        assertEq(token.totalSupply(), SUPPLY, "supply after launch");
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer balance after launch");
        assertEq(token.balanceOf(address(0)), 0, "nothing minted to the zero address");
        assertEq(token.balanceOf(address(this)), 0, "nothing minted to the test (the factory's deployer)");
    }

    function test_constructorEmitsSingleMintTransfer() public {
        address deployer = makeAddr("fresh-deployer");
        vm.recordLogs();
        vm.prank(deployer);
        YFDToken fresh = new YFDToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emits exactly one event");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0), "mint comes from the zero address");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), deployer, "mint goes to msg.sender");
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY, "mint is the whole supply");
    }

    function test_eachDeploymentMintsToItsOwnDeployerOnly() public {
        vm.prank(alice);
        YFDToken second = new YFDToken();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(address(factory)), 0, "a second instance owes the first deployer nothing");
        assertEq(token.balanceOf(alice), 0, "the first instance is untouched by a second deployment");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorTakesNoArguments() public {
        // Creation code that is exactly the compiled creation code (no appended constructor args)
        // deploys. The manifest states `constructorArgs: []`, so the bytecode must stand alone.
        bytes memory code = type(YFDToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "bare creation code must deploy");
        assertEq(YFDToken(deployed).balanceOf(address(this)), SUPPLY);
    }

    function test_metadataAndSupplyConstant() public view {
        assertEq(token.name(), "Yield Fields Deed");
        assertEq(token.symbol(), "YFD");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.TOTAL_SUPPLY(), 1000000000000000000000000000);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    // ───────────────────────────── transfer edges ─────────────────────────────

    function test_transferZeroSucceedsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0), "zero transfer from an empty account returns true");
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferOneWei() public {
        factory.move(alice, 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferWholeSupplyThenNothingLeft() public {
        assertTrue(factory.move(alice, SUPPLY));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        // The same call twice: the second has nothing to move.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), 0, SUPPLY)
        );
        factory.move(alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferOneOverBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        factory.move(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "a failed transfer moved nothing");
    }

    function test_transferMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, type(uint256).max
            )
        );
        factory.move(alice, type(uint256).max);
    }

    function test_selfTransferKeepsBalance() public {
        factory.move(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 10 ether));
        assertEq(token.balanceOf(alice), 10 ether, "a self-transfer neither doubles nor loses");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transfer(alice, 10 ether + 1);
    }

    function test_transferToSelfContractIsAllowedAndStranded() public {
        // Nothing stops tokens being sent to the token contract itself; there is no recovery path.
        // This is standard ERC-20 behaviour and the README documents that lost tokens stay lost.
        factory.move(address(token), 5);
        assertEq(token.balanceOf(address(token)), 5);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToZeroAddressRevertsEvenForZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    // ───────────────────────────── approval edges ─────────────────────────────

    function test_approveZeroSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_approveOverwritesNotAccumulates() public {
        vm.startPrank(alice);
        assertTrue(token.approve(bob, 100));
        assertTrue(token.approve(bob, 40));
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 40, "approve sets, it does not add");
        vm.prank(alice);
        assertTrue(token.approve(bob, 0));
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_approveEmitsApproval() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(alice, bob, 7);
        vm.prank(alice);
        token.approve(bob, 7);
    }

    function test_approveWithoutBalanceIsAllowedButUnspendable() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, bob), 1 ether, "a reverted transferFrom spends no allowance");
    }

    function test_transferFromExactAllowanceDrainsToZero() public {
        factory.move(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 10));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromOneOverAllowanceReverts() public {
        factory.move(alice, 100);
        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10, 11));
        token.transferFrom(alice, bob, 11);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.allowance(alice, bob), 10);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        factory.move(alice, 50);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 50);
        assertEq(token.allowance(alice, bob), type(uint256).max, "max allowance is never spent");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromDoesNotEmitApprovalOnSpend() public {
        factory.move(alice, 5);
        vm.prank(alice);
        token.approve(bob, 5);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, bob, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event on transferFrom");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(token.allowance(alice, bob), 2);
    }

    function test_transferFromByOwnerStillNeedsSelfAllowance() public {
        factory.move(alice, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 5));
        token.transferFrom(alice, bob, 5);
    }

    function test_transferFromToZeroAddressReverts() public {
        factory.move(alice, 5);
        vm.prank(alice);
        token.approve(bob, 5);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 5);
        assertEq(token.allowance(alice, bob), 5, "a reverted transferFrom spends no allowance");
    }

    function test_strangerCannotSpendDeployerSupply() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        token.transferFrom(address(factory), stranger, 1);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_allowanceIsPerPair() public {
        factory.move(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);
        // stranger has no allowance although bob does
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        token.transferFrom(alice, stranger, 1);
        // bob cannot use alice's allowance to spend from someone else
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(factory), bob, 1);
    }

    // ───────────────────────────── no admin surface, no ether ─────────────────────────────

    function test_tokenRejectsEtherAndUnknownSelectors() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "the token has no receive()");
        vm.prank(stranger);
        (ok,) = address(token).call{value: 0}("");
        assertFalse(ok, "the token has no fallback()");
        vm.prank(stranger);
        (ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "unknown selectors revert");
        assertEq(address(token).balance, 0);
    }

    function test_noAdminCallIncreasesSupplyFromAnyCaller() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        address[2] memory callers = [stranger, address(factory)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], stranger, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
                assertEq(token.totalSupply(), SUPPLY, signatures[i]);
                assertEq(token.balanceOf(stranger), 0, signatures[i]);
            }
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(alice, SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);
        string[14] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "burn(uint256)",
            "clawback(address,uint256)"
        ];
        address[3] memory callers = [address(factory), address(this), stranger];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
                assertFalse(ok, signatures[i]);
            }
        }
        // The deployer, the most plausibly trusted address, cannot pull without an allowance.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        vm.prank(address(factory));
        token.transferFrom(alice, address(factory), 1);
        assertEq(token.balanceOf(alice), held, "no privileged call moved the holder's balance");
        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2, "the holder can still transfer exact amounts");
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestructAndFitsEIP170() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, RUNTIME_LIMIT, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ───────────────────────────── launch flows, exact amounts ─────────────────────────────

    function test_launchFlowsMoveExactlyWhatTheyState() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * 5_000) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(distributor, swarm), "distributor transfer returned false");
        assertEq(token.balanceOf(distributor), swarm, "swarm share arrived short");

        PoolManagerProbe manager = new PoolManagerProbe();
        assertTrue(factory.approve(address(manager), pool));
        assertTrue(manager.pull(token, address(factory), pool), "seed pull returned false");
        assertEq(token.balanceOf(address(manager)), pool, "seed arrived short");
        assertEq(token.allowance(address(factory), address(manager)), 0, "seed allowance fully consumed");

        assertTrue(factory.move(requester, remainder), "remainder transfer returned false");
        assertEq(token.balanceOf(requester), remainder, "remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");

        // Claims: the distributor pays out whole.
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm, "claim arrived short");
        assertEq(token.balanceOf(distributor), 0);

        // A trade: the pool pays a trader, the trader sells back.
        assertTrue(manager.push(token, alice, 123_456_789));
        assertEq(token.balanceOf(alice), 123_456_789, "buy arrived short");
        vm.prank(alice);
        token.approve(address(manager), 123_456_789);
        assertTrue(manager.pull(token, alice, 123_456_789));
        assertEq(token.balanceOf(alice), 0, "sell left dust");
        assertEq(token.balanceOf(address(manager)), pool, "pool is whole after a round trip");

        assertEq(token.totalSupply(), SUPPLY, "launch flows changed the supply");
        assertEq(
            token.balanceOf(claimant) + token.balanceOf(address(manager)) + token.balanceOf(requester),
            SUPPLY,
            "launch flows lost or created tokens"
        );
    }

    // ───────────────────────────── fuzzed properties ─────────────────────────────

    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        if (held > 0) factory.move(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_transferWithinBalanceMovesExactly(uint256 held, uint256 amount, address to) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        if (to == address(0)) to = bob; // the zero receiver is its own pinned failure-path test
        if (held > 0) factory.move(alice, held);
        uint256 toBefore = token.balanceOf(to);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        assertTrue(token.transfer(to, amount));
        if (to == alice) {
            assertEq(token.balanceOf(alice), aliceBefore);
        } else {
            assertEq(token.balanceOf(alice), aliceBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromAboveAllowanceAlwaysReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, allowed + 1, type(uint256).max);
        factory.move(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount));
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, bob), allowed);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 1, type(uint256).max);
        amount = bound(amount, 0, held < allowed ? held : allowed);
        factory.move(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, stranger, amount));
        assertEq(token.balanceOf(alice), held - amount);
        assertEq(token.balanceOf(stranger), amount);
        assertEq(token.balanceOf(bob), 0, "the spender does not receive what it routes elsewhere");
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(alice, bob), type(uint256).max);
        } else {
            assertEq(token.allowance(alice, bob), allowed - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_twoHopTransferConservesSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        factory.move(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b);
    }

    function testFuzz_noBalanceExceedsSupply(address who) public view {
        assertLe(token.balanceOf(who), SUPPLY);
    }

    function testFuzz_approveIsIdempotentAndOverwrites(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        token.approve(bob, first);
        token.approve(bob, first);
        assertEq(token.allowance(alice, bob), first);
        token.approve(bob, second);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), second);
        assertEq(token.allowance(bob, alice), 0, "allowance is directional");
    }
}
