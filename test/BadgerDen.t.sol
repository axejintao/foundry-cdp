// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

import {SafeTransferLib} from "../lib/solmate/src/utils/SafeTransferLib.sol";

import { BadgerDen } from "../src/BadgerDen.sol";
import { ERC20 } from "../lib/solmate/src/tokens/ERC20.sol";
import { AggregatorV3Interface, AggregatorV2V3Interface } from "../src/interfaces/Oracle.sol";

contract SampleContractTest is Test {
    using SafeTransferLib for ERC20;
    
    uint256 public constant mockRoundId = 73786976294838207547;
    uint256 public constant mockAnswer = 13720414700000000000;

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

    // set up a vault with 10e available to borrow
    function setupBasicVault() public {
        getSomeToken(address(this), 100e18);
        den.createVault();
        WETH.safeApprove(address(den), 100e18);
        den.deposit(0, 10e18);
    }
    
    // set up a eth<>btc ratio of 13.7204147 eth / btc
    // TODO: consider fuzzing of ratio tests
    function setupBorrowEnabledVault() public {
        setupBasicVault();
        vm.mockCall(
            address(den.ORACLE()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(mockRoundId, mockAnswer, block.timestamp, block.timestamp, mockRoundId)
        );
    }

    // verify expected fields are set and visible
    function testBasicSetupWorks() public view {
        assert(address(den.EBTC()) != address(0));
        assert(den.COLLATERAL() == WETH);
        assert(den.ORACLE() == ORACLE);
    }

    // verify vault creation changes state appropriately
    function testCreateVault() public {
        uint256 vaultId = den.createVault();
        assert(vaultId == 0);
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
        setupBorrowEnabledVault();

        uint256 withdrawAmount = 5e18;
        uint256 beforeBalance = WETH.balanceOf(address(this));
        (uint256 beforeWithdrawOne, ) = den.getVaultState(0);
        assert(beforeWithdrawOne == 10e18);
        den.withdraw(0, withdrawAmount);
        (uint256 afterWithdrawOne, ) = den.getVaultState(0);
        assert(afterWithdrawOne == withdrawAmount);
        assert(beforeBalance + withdrawAmount == WETH.balanceOf(address(this)));

        vm.clearMockedCalls();
    }

    // verify user cannot borrow from another users vaults
    function testFailBorrowOtherVault() public {
        getSomeToken(address(WETH), 100e18);
        vm.startPrank(address(WETH));
        den.createVault();
        den.deposit(0, 1e18);
        vm.stopPrank();

        den.borrow(0, 1e18);
    }

    // verify you cannot borrow against no collateral
    function testFailBorrowNoCollateral() public {
        den.createVault();

        den.borrow(0, 1e18);
    }

    // verify you cannot borrow past imposed debt limit
    function testFailBorrowPastDebtLimit() public {
        setupBorrowEnabledVault();

        den.borrow(0, 1e18);
        vm.clearMockedCalls();
    }

    // verify you cannot borrow with stale oracle answer
    function testFailBorrowStaleRatio() public {
        setupBorrowEnabledVault();

        uint256 timestamp = block.timestamp - 2 hours;
        vm.mockCall(
            address(den.ORACLE()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(mockRoundId, mockAnswer, timestamp, timestamp, mockRoundId)
        );
        den.borrow(0, 1e18);
        vm.clearMockedCalls();
    }

    function testBorrow() public {
        setupBorrowEnabledVault();

        uint256 borrowAmount = 125e15;
        den.borrow(0, borrowAmount);
        assert(den.EBTC().balanceOf(address(this)) == borrowAmount);
        (uint256 collateral, uint256 borrowed) = den.getVaultState(0);
        assert(collateral == 10e18);
        assert(borrowed == borrowAmount);

        den.borrow(0, borrowAmount);
        assert(den.EBTC().balanceOf(address(this)) == borrowAmount * 2);
        (, uint256 newBorrowed) = den.getVaultState(0);
        assert(newBorrowed == borrowAmount * 2);
        vm.clearMockedCalls();
    }

    function testFailRepayNoDebt() public {
        setupBasicVault();

        den.repay(0, 1e18);
    }

    function testFailRepayOverDebt() public {
        setupBasicVault();
        den.borrow(0, 25e16);

        den.repay(0, 1e18);
    }

    function testRepay() public {
        setupBorrowEnabledVault();

        uint256 borrowAmount = 125e15;
        den.borrow(0, borrowAmount);
        assert(den.EBTC().balanceOf(address(this)) == borrowAmount);

        den.repay(0, borrowAmount);
        assert(den.EBTC().balanceOf(address(this)) == 0);
        (, uint256 borrowed) = den.getVaultState(0);
        assert(borrowed == 0);
        vm.clearMockedCalls();
    }

    // verify you cannot withdraw while borrowing
    function testFailWithdrawWithBorrow() public {
        setupBorrowEnabledVault();

        uint256 borrowAmount = 125e15;
        den.borrow(0, borrowAmount);

        den.withdraw(0, 10e18);
        vm.clearMockedCalls();
    }

    function testWithdrawAfterBorrowRepaid() public {
        setupBorrowEnabledVault();

        uint256 borrowAmount = 125e15;
        den.borrow(0, borrowAmount);

        den.repay(0, borrowAmount);

        den.withdraw(0, 10e18);
        vm.clearMockedCalls();
    }
}
