// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

import {SafeTransferLib} from "../lib/solmate/src/utils/SafeTransferLib.sol";

import { BadgerDen } from "../src/BadgerDen.sol";
import { ERC20 } from "../lib/solmate/src/tokens/ERC20.sol";
import { AggregatorV2V3Interface } from "../src/interfaces/Oracle.sol";

// Useful links
// How to steal tokens for forknet: 
// https://github.com/foundry-rs/forge-std/blob/2a2ce3692b8c1523b29de3ec9d961ee9fbbc43a6/src/Test.sol#L118-L150
// All the basics
// https://github.com/dabit3/foundry-cheatsheet
// Foundry manual
// https://book.getfoundry.sh/cheatcodes/


contract SampleContractTest is Test {
    using SafeTransferLib for ERC20;
    
    ERC20 public constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    AggregatorV2V3Interface public constant ORACLE = AggregatorV2V3Interface(0xdeb288F737066589598e9214E782fa5A8eD689e8);

    BadgerDen den;

    function setUp() public {
        den = new BadgerDen();
    }

    function getSomeToken() internal {
        // become whale
        vm.prank(0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E);
        WETH.safeTransfer(address(this), 123e18);
        assert(WETH.balanceOf(address(this)) == 123e18);
    }

    function testBasicSetupWorks() public view {
        assert(den.COLLATERAL() == WETH);
        assert(den.ORACLE() == ORACLE);
    }

    function testBasicDeposit() public {
        // Test is scoped so you need to re-do setup each test
        getSomeToken();

        WETH.safeApprove(address(den), 42069);
        den.deposit(0, 1337);

        assert(den.nextVaultId() == 1);
        assert(den.balanceOf(address(this)) == 1);
        assert(den.ownerOf(0) == address(this));

        (uint256 collateral,) = den.getVaultState(0);
        assert(collateral == 1337);

        den.deposit(1, 1337);
        uint256 vault0 = den.getUserVaults(address(this), 0);
        assert(vault0 == 0);
        uint256 vault1 = den.getUserVaults(address(this), 1);
        assert(vault1 == 1);

        den.deposit(1, 1337);
        (uint256 increasedCollateral,) = den.getVaultState(1);
        assert(increasedCollateral == 1337 * 2);
    }

    function testFailInvalidVaultDeposit() public {
        getSomeToken();

        WETH.safeApprove(address(den), 1337);

        den.deposit(1, 1337);
    }

    function testFailBasicDepositMissingFunds() public {
        WETH.safeApprove(address(den), 1337);

        den.deposit(0, 1337);
    }
}
