// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {YFDToken} from "../src/YFDToken.sol";

contract YFDTokenTest is Test {
    YFDToken token;
    address deployer = address(0xFAC7);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vm.prank(deployer);
        token = new YFDToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Yield Fields Deed");
        assertEq(token.symbol(), "YFD");
        assertEq(token.decimals(), 18);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1000 ether));
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 500 ether);
        vm.prank(alice);
        assertTrue(token.approve(bob, 200 ether));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 150 ether));
        assertEq(token.balanceOf(bob), 150 ether);
        assertEq(token.allowance(alice, bob), 50 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_noMintOrAdminEntrypoints() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "transferOwnership(address)",
            "pause()",
            "burnFrom(address,uint256)",
            "owner()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], alice, SUPPLY));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
