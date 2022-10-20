// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// NOTE: Solmate doesn't check for token existence, this may cause bugs if you enable any collateral
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC721 } from "@openzeppelin/token/ERC721/ERC721.sol";
import { ERC721Enumerable } from "@openzeppelin/token/ERC721/extensions/ERC721Enumerable.sol";

import { AggregatorV2V3Interface } from "./interfaces/Oracle.sol";
import { eBTC } from "./eBTC.sol";

// TODO: transfer from will break the user vault mapping, consider erc721 enumerable
// construct a naive multiparty cdp based on WETH collateral and ChainLink oracle pricing for btc
contract BadgerDen is ERC721Enumerable {
    using SafeTransferLib for ERC20;

    struct VaultState {
        uint256 collateral;
        uint256 borrowed;
    }

    uint256 constant RATIO_DECIMALS = 10 ** 8;
    uint256 constant NUMERATOR = 1e36; // is there a better way to do this, gives 18 decimal rate

    // TODO: should this naming convention be ugly EBtc? :(
    eBTC immutable public EBTC;
    ERC20 immutable public COLLATERAL;
    AggregatorV2V3Interface immutable public ORACLE;

    mapping(uint256 => VaultState) public getVaultState;

    uint256 loanToValue = 8e17; 
    // allow vault id zero to be used as a canary
    uint256 public nextVaultId = 0;
    uint256 public totalDeposited;
    uint256 public totalBorrowed;

    event Debug(string name, uint256 amount);

    constructor() ERC721("eBTC Collateralized Debt Position", "eBTC-CDP") {
        EBTC = new eBTC();
        COLLATERAL = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
        ORACLE = AggregatorV2V3Interface(0xdeb288F737066589598e9214E782fa5A8eD689e8);
    }

    // lol let anyone set the ltv 
    function setLoanToValue(uint256 _loanToValue) external {
        loanToValue = _loanToValue;
    }

    function createVault() public {
        // are these references need to be cached?
        getVaultState[nextVaultId] = VaultState(0, 0);
        _mint(msg.sender, nextVaultId);
        nextVaultId++;
    }

    // Deposit
    function deposit(uint256 _vaultId, uint256 _amount) external {
        require(COLLATERAL.balanceOf(msg.sender) >= _amount, "Insufficient collateral");
        require(_vaultId < nextVaultId, "Invalid vaultId");

        // Increase deposited
        totalDeposited += _amount;
        getVaultState[_vaultId].collateral += _amount;

        // Check delta + transfer
        uint256 prevBal = COLLATERAL.balanceOf(address(this));
        COLLATERAL.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBal = COLLATERAL.balanceOf(address(this));

        // Make sure we got the amount we expected
        require(afterBal - prevBal == _amount, "No feeOnTransfer");   
    }

    // Withdraw
    function withdraw(uint256 _vaultId, uint256 _amount) external {
        require(ownerOf(_vaultId) == msg.sender, "Withdraw against non owned collateral");
        VaultState memory vaultState = getVaultState[_vaultId];
        require(vaultState.collateral >= _amount, "Withdraw against insufficient collateral");

        uint256 remainingCollateral = vaultState.collateral - _amount;
        uint256 remainingBorrowAvailable = getCollateralBorrow(remainingCollateral);
        require(vaultState.borrowed <= remainingBorrowAvailable, "Withdraw will cause liquidation");
        
        getVaultState[nextVaultId] = VaultState(vaultState.collateral - _amount, vaultState.borrowed);

        uint256 prevBal = COLLATERAL.balanceOf(address(this));
        COLLATERAL.safeTransferFrom(address(this), msg.sender, _amount);
        uint256 afterBal = COLLATERAL.balanceOf(address(this));

        require(afterBal - prevBal == _amount, "No feeOnTransfer");   
    }

    // Borrow
    function borrow(uint256 _vaultId, uint256 _amount) external {
        require(ownerOf(_vaultId) == msg.sender, "Borrow against non owned collateral");
        uint256 collateral = getVaultState[_vaultId].collateral;
        require(collateral != 0, "Borrow against no collateral");

        // Checks
        uint256 borrowCached = getVaultState[_vaultId].borrowed;
        getVaultState[_vaultId].borrowed = borrowCached + _amount;
        
        // Check if borrow is solvent
        uint256 maxBorrowCached = getCollateralBorrow(collateral);
        emit Debug("maxBorrowCached", maxBorrowCached);

        // how does the caching there help?
        require(borrowCached <= maxBorrowCached, "Over debt limit");

        // Effect
        totalBorrowed += _amount;

        // Interaction
        EBTC.mint(msg.sender, _amount);
    }

    // Repay
    // TODO: does it matter if someone repays on behalf of someone else?
    // TODO: difference between repay and liquidate, who is calling - and an incentive?
    function repay(uint256 _vaultId, uint256 _amount) external {
        uint256 borrowed = getVaultState[_vaultId].borrowed;
        require(borrowed != 0, "Repay against no debt");
        require(borrowed <= _amount, "Repay greater than debt");

        getVaultState[_vaultId].borrowed -=  _amount;
        totalBorrowed -= _amount;

        uint256 prevBal = EBTC.balanceOf(msg.sender);
        emit Debug("prevBal", prevBal);
        EBTC.burn(msg.sender, _amount);
        uint256 afterBal = EBTC.balanceOf(address(this));
        require(afterBal - prevBal == _amount, "Require appropriate payment");
    }

    // Liquidate
    // TODO: this is probably so gas inefficient :( t11s rolling in his grave
    // TODO: think about liquidation incentives, and properly liquidating the correct amount
    // TODO: there are boundary checks here that need to be added, there are also liquidation bonus possible
    function liquidate(uint256 _vaultId, uint256 _amount) external {
        VaultState memory vaultState = getVaultState[_vaultId];
        uint256 maxBorrow = getCollateralBorrow(vaultState.collateral);
        require(vaultState.borrowed > maxBorrow, "Target vault is solvent");

        // unsafe, need to add some data checks here
        (, int256 collateralPerToken,,,) = ORACLE.latestRoundData(); 
        uint256 liquidatedCollateral = uint256(collateralPerToken) * _amount;

        uint256 remainingCollateral = vaultState.collateral - liquidatedCollateral;
        uint256 outstandingBorrowed = vaultState.borrowed - _amount;
        getVaultState[_vaultId] = VaultState(remainingCollateral, outstandingBorrowed);

        // burn 
        uint256 prevDebtBalance = EBTC.balanceOf(msg.sender);
        EBTC.burn(msg.sender, _amount);
        uint256 afterDebtBalance = EBTC.balanceOf(address(this));

        // Make sure we got the amount we expected
        require(afterDebtBalance - prevDebtBalance == _amount, "Require appropriate payment");

        // pay liquidator
        uint256 prevCollateralBalance = COLLATERAL.balanceOf(address(this));
        COLLATERAL.safeTransferFrom(address(this), msg.sender, liquidatedCollateral);
        uint256 afterCollateralBalance = COLLATERAL.balanceOf(address(this));

        // Make sure we pay the amount we expected
        require(afterCollateralBalance - prevCollateralBalance == _amount, "Require appropriate payment");
    }

    // given you have data for the positions you can make a fun png with this info
    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return "";
    }

    function getCollateralBorrow(uint256 _collateral) public view returns (uint256) {
        uint256 maxCollateral = _collateral * loanToValue / RATIO_DECIMALS;
        return maxCollateral * getTokensPerCollateral();
    }

    // TODO: this is a naive check, really would want to scrutinize
    function getTokensPerCollateral() public view returns (uint256) {
        // unsafe, need to add some data checks here
        (, int256 answer,,,) = ORACLE.latestRoundData(); 
        return NUMERATOR / uint256(answer);
    }
}