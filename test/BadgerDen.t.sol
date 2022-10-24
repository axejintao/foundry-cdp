// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

import {SafeTransferLib} from "../lib/solmate/src/utils/SafeTransferLib.sol";

import { BadgerDen } from "../src/BadgerDen.sol";
import { ERC20 } from "../lib/solmate/src/tokens/ERC20.sol";
import { AggregatorV2V3Interface } from "../src/interfaces/Oracle.sol";

contract SampleContractTest is Test {
    using SafeTransferLib for ERC20;
    
    ERC20 public constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    AggregatorV2V3Interface public constant ORACLE = AggregatorV2V3Interface(0xdeb288F737066589598e9214E782fa5A8eD689e8);

    BadgerDen den;

    function setUp() public {
        den = new BadgerDen();
    }

    function getSomeToken(address target, uint256 amount) internal {
        vm.prank(0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E);
        WETH.safeTransfer(target, amount);
        assert(WETH.balanceOf(target) == amount);
    }

    function setupBasicVault() public {
        getSomeToken(address(this), 100e18);
        den.createVault();
        WETH.safeApprove(address(den), 100e18);
        den.deposit(0, 10e18);
    }

    // verify expected fields are set and visible
    function testBasicSetupWorks() public view {
        assert(address(den.EBTC()) != address(0));
        assert(den.COLLATERAL() == WETH);
        assert(den.ORACLE() == ORACLE);
    }

    // verify vault creation changes state appropriately
    function testCreateVault() public {
        den.createVault();
        assert(den.nextVaultId() == 1);
        assert(den.balanceOf(address(this)) == 1);
        assert(den.ownerOf(0) == address(this));

        uint256 vault = den.tokenOfOwnerByIndex(address(this), 0);
        assert(vault == 0);

        (uint256 collateral, uint256 borrowed) = den.getVaultState(0);
        assert(collateral == 0);
        assert(borrowed == 0);
    }

    // verify inability to deposit in vaults that do not exist
    function testFailDepositNoVault() public {
        getSomeToken(address(this), 100e18);
        WETH.safeApprove(address(den), 1e18);
        
        den.deposit(0, 1e18);
    }

    // verify multiple deposits against a given vault properly track collateral
    function testDeposit() public {
        getSomeToken(address(this), 100e18);
        WETH.safeApprove(address(den), 100e18);
        den.createVault();

        den.deposit(0, 5e17);

        // verify the collateral was counted
        (uint256 collateral, uint256 borrowed) = den.getVaultState(0);
        assert(collateral == 5e17);
        assert(borrowed == 0);

        den.deposit(0, 5e17);

        // verify subsequent deposits are appropriately added
        (uint256 newCollateral, uint256 newBorrowed) = den.getVaultState(0);
        assert(newCollateral == 1e18);
        assert(newBorrowed == 0);
    }

    // verify user must pay funds to get credited
    function testFailBasicDepositMissingFunds() public {
        WETH.safeApprove(address(den), 1e18);

        den.deposit(0, 1e18);
    }

    // verify an error is thrown when withdraw from another user vault
    function testFailWithdrawOtherVault() public {
        getSomeToken(address(WETH), 100e18);
        vm.startPrank(address(WETH));
        den.createVault();
        den.deposit(0, 1e18);
        vm.stopPrank();

        den.withdraw(0, 1e18);
    }

    // verify an error is thrown when withdraw more than collateral
    function testFailWithdrawOverMax() public {
        setupBasicVault();

        den.withdraw(1, 11e18);
    }

    // verify basic withdraw flow functionality
    function testWithdrawNoBorrow() public {
        setupBasicVault();

        uint256 withdrawAmount = 5e18;
        uint256 beforeBalance = WETH.balanceOf(address(this));
        (uint256 beforeWithdrawOne, ) = den.getVaultState(0);
        assert(beforeWithdrawOne == 10e18);
        den.withdraw(0, withdrawAmount);
        (uint256 afterWithdrawOne, ) = den.getVaultState(0);
        assert(afterWithdrawOne == withdrawAmount);
        assert(beforeBalance + withdrawAmount == WETH.balanceOf(address(this)));
    }
}
