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
        vm.prank(0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E);
        WETH.safeTransfer(address(this), 100e18);
        assert(WETH.balanceOf(address(this)) == 100e18);
    }

    function testBasicSetupWorks() public view {
        assert(address(den.EBTC()) != address(0));
        assert(den.COLLATERAL() == WETH);
        assert(den.ORACLE() == ORACLE);
    }

    function testCreateVault() public {
        den.createVault();
        assert(den.nextVaultId() == 1);
        assert(den.balanceOf(address(this)) == 1);
        assert(den.ownerOf(0) == address(this));
        (uint256 collateral, uint256 borrowed) = den.getVaultState(0);
        assert(collateral == 0);
        assert(borrowed == 0);
    }

    function testFailDepositNoVault() public {
        getSomeToken();
        WETH.safeApprove(address(den), 1e18);
        
        den.deposit(0, 1e18);
    }

    function testDeposit() public {
        getSomeToken();
        WETH.safeApprove(address(den), 100e18);
        den.createVault();

        den.deposit(0, 5e17);

        (uint256 collateral, uint256 borrowed) = den.getVaultState(0);
        assert(collateral == 5e17);
        assert(borrowed == 0);

        uint256 vault = den.tokenOfOwnerByIndex(address(this), 0);
        assert(vault == 0);

        den.deposit(0, 5e17);

        (uint256 newCollateral, uint256 newBorrowed) = den.getVaultState(0);
        assert(newCollateral == 1e18);
        assert(newBorrowed == 0);
    }

    function testFailInvalidVaultDeposit() public {
        getSomeToken();

        WETH.safeApprove(address(den), 1e18);

        den.deposit(1, 1e18);
    }

    function testFailBasicDepositMissingFunds() public {
        WETH.safeApprove(address(den), 1e18);

        den.deposit(0, 1e18);
    }
}
