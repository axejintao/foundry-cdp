// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC721 } from "@openzeppelin/token/ERC721/ERC721.sol";
import { ERC721Enumerable } from "@openzeppelin/token/ERC721/extensions/ERC721Enumerable.sol";

import { AggregatorV2V3Interface } from "./interfaces/Oracle.sol";
import { eBTC } from "./eBTC.sol";

contract BadgerDen is ERC721Enumerable {
    using SafeTransferLib for ERC20;

    struct VaultState {
        uint256 collateral;
        uint256 borrowed;
    }

    uint256 constant RATIO_DECIMALS = 1e18;
    uint256 constant NUMERATOR = 1e36;

    eBTC immutable public EBTC;
    ERC20 immutable public COLLATERAL;
    AggregatorV2V3Interface immutable public ORACLE;

    mapping(uint256 => VaultState) public getVaultState;

    uint256 loanToValue = 8e17;
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

    function createVault() public returns (uint256 vaultId) {
        getVaultState[nextVaultId] = VaultState(0, 0);
        _mint(msg.sender, nextVaultId);
        unchecked {
            vaultId = nextVaultId++;
        }
    }

    // Deposit
    function deposit(uint256 _vaultId, uint256 _amount) external {
        require(COLLATERAL.balanceOf(msg.sender) >= _amount, "Insufficient collateral");
        require(_vaultId < nextVaultId, "Invalid vaultId");

        totalDeposited += _amount;
        unchecked {
            getVaultState[_vaultId].collateral += _amount;
        }

        COLLATERAL.safeTransferFrom(msg.sender, address(this), _amount);
    }

    // Withdraw
    function withdraw(uint256 _vaultId, uint256 _amount) external {
        require(ownerOf(_vaultId) == msg.sender, "Withdraw against non owned collateral");
        VaultState memory vaultState = getVaultState[_vaultId];
        require(vaultState.collateral >= _amount, "Withdraw against insufficient collateral");

        uint256 remainingCollateral = vaultState.collateral - _amount;
        uint256 remainingBorrowAvailable = getCollateralBorrow(remainingCollateral);
        require(vaultState.borrowed <= remainingBorrowAvailable, "Withdraw will cause liquidation");
        
        getVaultState[_vaultId] = VaultState(vaultState.collateral - _amount, vaultState.borrowed);
        COLLATERAL.safeTransferFrom(address(this), msg.sender, _amount);
    }

    // Borrow
    function borrow(uint256 _vaultId, uint256 _amount) external {
        require(ownerOf(_vaultId) == msg.sender, "Borrow against non owned collateral");
        uint256 collateral = getVaultState[_vaultId].collateral;
        require(collateral != 0, "Borrow against no collateral");

        uint256 borrowCached = getVaultState[_vaultId].borrowed + _amount;
        require(borrowCached <= getCollateralBorrow(collateral), "Over debt limit");

        totalBorrowed += _amount;
        unchecked {
            getVaultState[_vaultId].borrowed = borrowCached;
        }

        EBTC.mint(msg.sender, _amount);
    }

    // Repay
    function repay(uint256 _vaultId, uint256 _amount) external {
        uint256 borrowed = getVaultState[_vaultId].borrowed;
        require(borrowed != 0, "Repay against no debt");
        require(borrowed <= _amount, "Repay greater than debt");

        totalBorrowed -= _amount;
        unchecked {
            getVaultState[_vaultId].borrowed -= _amount;
        }
        EBTC.burn(msg.sender, _amount);
    }

    // Liquidate
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

        EBTC.burn(msg.sender, _amount);
        COLLATERAL.safeTransferFrom(address(this), msg.sender, liquidatedCollateral);
    }

    // given you have data for the positions you can make a fun png with this info
    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return "";
    }

    function getCollateralBorrow(uint256 _collateral) public view returns (uint256) {
        unchecked {
            uint256 maxCollateral = _collateral * loanToValue / RATIO_DECIMALS;
            return maxCollateral * getTokensPerCollateral() / RATIO_DECIMALS;
        }
    }

    function getTokensPerCollateral() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ORACLE.latestRoundData();
        // NOTE - this require statement bricks withdraw, borrow, liquidate while stale!
        require(updatedAt >= block.timestamp - 1 hours);
        return (NUMERATOR / uint256(answer));
    }
}