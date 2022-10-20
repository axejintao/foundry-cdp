// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// NOTE: Solmate doesn't check for token existence, this may cause bugs if you enable any collateral
import {SafeTransferLib} from "../lib/solmate/src/utils/SafeTransferLib.sol";

import { ERC20 } from "../lib/solmate/src/tokens/ERC20.sol";
import { ERC721 } from "../lib/solmate/src/tokens/ERC721.sol";

import { AggregatorV2V3Interface } from "./interfaces/Oracle.sol";
import { eBTC } from "./eBTC.sol";

enum RepayWith {
    DAI,
    COLLATERAL
}

struct VaultState {
    uint256 id;
    uint256 collateral;
    uint256 borrowed;
}

interface ICallbackRecipient {
    function flashMintCallback(address initiator, uint256 amount, bytes memory data) external returns (RepayWith, uint256);
}

// TODO: transfer from will break the user vault mapping, consider erc721 enumerable
// construct a naive multiparty cdp based on WETH collateral and ChainLink oracle pricing for btc
contract BadgerDen is ERC721 {
    using SafeTransferLib for ERC20;

    uint256 constant RATIO_DECIMALS = 10 ** 8;
    uint256 constant NUMERATOR = 1e36; // is there a better way to do this, gives 18 decimal rate

    // TODO: should this naming convention be ugly EBtc? :(
    eBTC immutable public EBTC;
    ERC20 immutable public COLLATERAL;
    AggregatorV2V3Interface immutable public ORACLE;

    // Vault Storage
    mapping(address => uint256[]) public getUserVaults;
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

    // Deposit
    // TODO: does it matter if someone deposits on behalf of someone else?
    function deposit(uint256 _vaultId, uint256 _amount) public {
        require(COLLATERAL.balanceOf(msg.sender) >= _amount, "Insufficient collateral");
        require(_vaultId <= nextVaultId, "Invalid vaultId");

        // create vault state for user if not available, increment vault id
        if (_vaultId == nextVaultId) {
            getVaultState[_vaultId] = VaultState(_vaultId, 0, 0);
            getUserVaults[msg.sender].push(_vaultId);
            _mint(msg.sender, _vaultId);
            nextVaultId++;
        }

        // Increase deposited
        totalDeposited += _amount;
        getVaultState[_vaultId].collateral += _amount;

        // Check delta + transfer
        uint256 prevBal = COLLATERAL.balanceOf(address(this));
        emit Debug("prevBal", prevBal);
        COLLATERAL.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBal = COLLATERAL.balanceOf(address(this));

        // Make sure we got the amount we expected
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
        uint256 maxBorrowCached = maxBorrow(_vaultId);
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
    function liquidate(uint256 _vaultId, uint256 _amount) external {
        require(!isSolvent(_vaultId), "Must be insolvent");

        uint256 excessDebt = totalBorrowed - maxBorrow(_vaultId);

        // Check delta + transfer
        uint256 prevBal = EBTC.balanceOf(msg.sender);
        emit Debug("prevBal", prevBal);
        EBTC.burn(msg.sender, _amount);
        uint256 afterBal = EBTC.balanceOf(address(this));

        // Make sure we got the amount we expected
        require(afterBal - prevBal == _amount, "Require appropriate payment");

        // Burn the token
        EBTC.burn(msg.sender, excessDebt);
    }

    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return "";
    }

    function maxBorrow(uint256 _vaultId) public view returns (uint256) {
        VaultState memory depositorVault = getVaultState[_vaultId];
        uint256 maxCollateral = depositorVault.collateral * loanToValue / RATIO_DECIMALS;
        return maxCollateral * getTokensPerCollateral();
    }

    function isSolvent(uint256 _vaultId) public view returns (bool) {
        VaultState memory depositorVault = getVaultState[_vaultId];
        return depositorVault.borrowed <= maxBorrow(_vaultId);
    }

    // TODO: this is a naive check, really would want to scrutinize
    function getTokensPerCollateral() public view returns (uint256) {
        (, int256 answer,,,) = ORACLE.latestRoundData(); 
        return NUMERATOR / uint256(answer);
    }
}