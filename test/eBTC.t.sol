// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

import { eBTC } from "../src/eBTC.sol";

contract eBTCTest is Test {
    eBTC ebtc;

    function setUp() public {
        ebtc = new eBTC();
    }

    function testMint() public {
        uint256 currentBalance = ebtc.balanceOf(address(this));
        assert(currentBalance == 0);
        uint256 mintAmount = 100e18;
        ebtc.mint(address(this), mintAmount);
        uint256 newBalance = ebtc.balanceOf(address(this));
        assert(newBalance == mintAmount);
    }

    function testFailNoMintPermission() public {
        vm.prank(0x9EA5Dc47f140F6cF2C41b16d7555215eE27929ce);
        ebtc.mint(0x9EA5Dc47f140F6cF2C41b16d7555215eE27929ce, 10e18);
    }

    function testBurn() public {
        uint256 mintAmount = 100e18;
        ebtc.mint(address(this), mintAmount);
        uint256 currentBalance = ebtc.balanceOf(address(this));
        assert(currentBalance == mintAmount);
        ebtc.burn(address(this), mintAmount);
        uint256 newBalance = ebtc.balanceOf(address(this));
        assert(newBalance == 0);
    }

    function testFailNoBurnPermission() public {
        address targetAccount = 0x9EA5Dc47f140F6cF2C41b16d7555215eE27929ce;
        uint256 mintAmount = 100e18;
        ebtc.mint(targetAccount, mintAmount);
        uint256 currentBalance = ebtc.balanceOf(targetAccount);
        assert(currentBalance == mintAmount);
        vm.prank(targetAccount);
        ebtc.burn(targetAccount, 10e18);
    }
}