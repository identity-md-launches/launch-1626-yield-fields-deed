// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {YFDToken} from "../src/YFDToken.sol";

/// @notice Drives the token with a fixed set of actors (the deployer that holds the supply, a
/// distributor, a pool, a requester and a handful of holders) in random order with bounded and
/// unbounded inputs, and keeps ghost books of what every actor should hold and may spend.
contract YFDHandler is Test {
    YFDToken public immutable token;
    uint256 public immutable supply;

    address[] public actors;
    mapping(address => bool) public isActor;

    /// @dev Ghost books: what each actor should hold and what each allowance should be.
    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    /// @dev Tokens an actor sent out, in total, and received, in total.
    mapping(address => uint256) public ghost_sent;
    mapping(address => uint256) public ghost_received;

    uint256 public ghost_transfers;
    uint256 public ghost_transferFroms;
    uint256 public ghost_approves;
    uint256 public ghost_expectedReverts;
    uint256 public ghost_adminAttempts;

    constructor(YFDToken token_, address deployer, address[] memory others) {
        token = token_;
        supply = token_.totalSupply();
        _addActor(deployer);
        ghost_balance[deployer] = supply;
        for (uint256 i; i < others.length; ++i) {
            _addActor(others[i]);
        }
    }

    function _addActor(address a) internal {
        if (!isActor[a]) {
            isActor[a] = true;
            actors.push(a);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _bookTransfer(address from, address to, uint256 amount) internal {
        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
    }

    // ───────────────────────────── clamped: always succeed ─────────────────────────────

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer within balance must return true");
        _bookTransfer(from, to, amount);
        ghost_transfers++;
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        transfer(fromSeed, toSeed, token.balanceOf(from));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve must return true");
        ghost_allowance[owner][spender] = amount;
        ghost_approves++;
    }

    function approveMax(uint256 ownerSeed, uint256 spenderSeed) public {
        approve(ownerSeed, spenderSeed, type(uint256).max);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);
        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom within balance and allowance must return true");
        _bookTransfer(owner, to, amount);
        if (allowed != type(uint256).max) ghost_allowance[owner][spender] = allowed - amount;
        ghost_transferFroms++;
    }

    /// @dev Approve then spend in one handler, so the spend path is reached often.
    function approveAndTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, held);
        approve(ownerSeed, spenderSeed, amount);
        transferFrom(ownerSeed, spenderSeed, toSeed, amount);
    }

    // ───────────────────────────── unclamped: must fail exactly ─────────────────────────────

    /// @dev A transfer of more than the sender holds must revert with the exact error and move nothing.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;
        vm.prank(from);
        try token.transfer(to, amount) {
            revert("transfer above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount),
                "wrong revert for transfer above balance"
            );
        }
        ghost_expectedReverts++;
    }

    /// @dev A spend above the allowance must revert with the exact error, spending nothing.
    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount),
                "wrong revert for transferFrom above allowance"
            );
        }
        ghost_expectedReverts++;
    }

    /// @dev A spend within the allowance but above the owner's balance must revert on the balance.
    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount),
                "wrong revert for transferFrom above balance"
            );
        }
        ghost_expectedReverts++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
        ghost_expectedReverts++;
    }

    /// @dev Any caller, including the deployer, trying a privileged entrypoint must be refused.
    function adminAttempt(uint256 callerSeed, uint256 which, uint256 amount) public {
        address caller = _actor(callerSeed);
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "seize(address)",
            "setTransfersEnabled(bool)"
        ];
        string memory sig = signatures[bound(which, 0, signatures.length - 1)];
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, caller, amount));
        assertFalse(ok, sig);
        ghost_adminAttempts++;
    }

    /// @dev Ether sent at the token must bounce; it holds none.
    function sendEther(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, 1 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ether");
    }
}

/// @notice Invariants of a fixed-supply token over random call sequences: the supply never
/// changes, what the actors hold sums to the supply, every balance and allowance equals the
/// ghost book, nobody holds more than the supply, and the token never holds ether.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract YFDTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    YFDToken token;
    YFDHandler handler;
    address deployer = makeAddr("factory");

    function setUp() public {
        vm.prank(deployer);
        token = new YFDToken();

        address[] memory others = new address[](7);
        others[0] = makeAddr("distributor");
        others[1] = makeAddr("poolManager");
        others[2] = makeAddr("requester");
        others[3] = makeAddr("holder1");
        others[4] = makeAddr("holder2");
        others[5] = makeAddr("holder3");
        others[6] = makeAddr("holder4");
        handler = new YFDHandler(token, deployer, others);

        targetContract(address(handler));
    }

    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function invariant_sumOfActorBalancesIsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "tokens were created or lost");
    }

    function invariant_balancesMatchGhostBooks() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghost_balance(a), "balance drifted from the ghost book");
            uint256 initial = a == deployer ? SUPPLY : 0;
            assertEq(token.balanceOf(a), initial + handler.ghost_received(a) - handler.ghost_sent(a), "flow accounting");
            assertLe(token.balanceOf(a), SUPPLY, "a balance exceeds the supply");
        }
    }

    function invariant_allowancesMatchGhostBooks() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drifted");
            }
        }
    }

    function invariant_nobodySpendsMoreThanTheyReceived() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 initial = a == deployer ? SUPPLY : 0;
            assertLe(handler.ghost_sent(a), initial + handler.ghost_received(a), "spent more than held");
        }
    }

    function invariant_zeroAddressAndTokenHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "Yield Fields Deed");
        assertEq(token.symbol(), "YFD");
        assertEq(token.decimals(), 18);
    }
}
