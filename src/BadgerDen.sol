// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// NOTE: Solmate doesn't check for token existence, this may cause bugs if you enable any collateral
import {SafeTransferLib} from "../lib/solmate/src/utils/SafeTransferLib.sol";

import {ERC20} from "../lib/solmate/src/tokens/ERC20.sol";

import { AggregatorV2V3Interface } from "./interfaces/Oracle.sol";
import { eBTC } from "./eBTC.sol";

enum RepayWith {
    DAI,
    COLLATERAL
}

struct VaultState {
    uint256 id;
    uint256 collateral;
    uint256 borrow;
}

interface ICallbackRecipient {
    function flashMintCallback(address initiator, uint256 amount, bytes memory data) external returns (RepayWith, uint256);
}

// construct a naive multiparty cdp based on WETH collateral and ChainLink oracle pricing for btc
contract BadgerDen {
    using SafeTransferLib for ERC20;

    uint256 constant MAX_BPS = 10_000;
    uint256 constant LIQUIDATION_TRESHOLD = 10_000; // 100% in BPS
    uint256 constant RATIO_DECIMALS = 10 ** 8;

    // TODO: should this naming convention be ugly EBtc? :(
    eBTC immutable public EBTC;
    ERC20 immutable public COLLATERAL;

    // TODO: utilize address <> nft mappings to allow
    // for multiple positions per user with various risk 
    // i.e. one 5x position and one 2x positions with different sizings
    // also allows for positions to be passed between wallets to avoid need to unwind
    mapping(address => VaultState) public userVaults;
    mapping(uint256 => VaultState) public vaultIds;

    uint256 ratio = 8e17; 
    // allow vault id zero to be used as a canary
    uint256 currentVault = 1;
    uint256 totalDeposited;
    uint256 totalBorrowed;

    event Debug(string name, uint256 amount);

    constructor() {
        EBTC = new eBTC();
        COLLATERAL = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
    }

    // lol let anyone set the ltv 
    function setRatio(uint256 _ratio) external {
        ratio = _ratio;
    }

    function flash(uint256 amount, ICallbackRecipient target, bytes memory data) external {
        // No checks as we allow minting after

        // Effetcs
        uint256 newTotalBorrowed = totalBorrowed + amount;

        totalBorrowed = newTotalBorrowed;

        // Interactions
        // Flash mint amount
        // Safe because DAI is nonReentrant as we know impl
        EBTC.mint(address(target), amount);


        // Callback
        (RepayWith collateralChoice, uint256 repayAmount) = target.flashMintCallback(msg.sender, amount, data);


        // Check solvency
        if(totalBorrowed > maxBorrow(0)) {
            if(collateralChoice == RepayWith.DAI) {
                uint256 minRepay = totalBorrowed - maxBorrow(0);
                // They must repay
                // This is min repayment
                require(repayAmount >= minRepay);

                // TODO: This may be gameable must fuzz etc.. this is a toy project bruh
                totalBorrowed -= repayAmount;

                // Get the repayment
                // DAI Cannot reenter because we know impl, DO NOT ADD HOOKS OR YOU WILL GET REKT
                EBTC.burn(address(target), repayAmount);
            } else {
                // They repay with collateral

                // NOTE: WARN
                // This can reenter for sure, DO NOT USE IN PROD
                deposit(repayAmount);

                assert(isSolvent(0));
            }
        }
    }

    // Deposit
    function deposit(uint256 amount) public {
        VaultState memory depositorVault = userVaults[msg.sender];

        // create vault state for user if not available, increment vault id
        if (depositorVault.id == 0) {
            depositorVault = VaultState(currentVault, 0, 0);
            vaultIds[currentVault] = depositorVault;
            userVaults[msg.sender] = depositorVault;
            currentVault++;
        }

        // Increase deposited
        totalDeposited += amount;
        depositorVault.collateral += amount;

        // Check delta + transfer
        uint256 prevBal = COLLATERAL.balanceOf(address(this));
        emit Debug("prevBal", prevBal);
        COLLATERAL.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = COLLATERAL.balanceOf(address(this));

        // Make sure we got the amount we expected
        require(afterBal - prevBal == amount, "No feeOnTransfer");   
    }

    // Borrow
    function borrow(uint256 amount) external {
        VaultState memory depositorVault = userVaults[msg.sender];
        require(depositorVault.id != 0 && depositorVault.collateral != 0, "Borrow against no collateral");

        // Checks
        depositorVault.borrow += amount;
        
        // Check if borrow is solvent
        uint256 maxBorrowCached = maxBorrow(depositorVault.id);

        require(depositorVault.borrow <= maxBorrowCached, "Over debt limit");

        // Effect
        totalBorrowed += amount;

        // Interaction
        EBTC.mint(msg.sender, amount);
    }

    function maxBorrow(uint256 _vaultId) public view returns (uint256) {
        VaultState memory depositorVault = vaultIds[_vaultId];
        return depositorVault.collateral * ratio / RATIO_DECIMALS;
    }

    function isSolvent(uint256 _vaultId) public view returns (bool) {
        VaultState memory depositorVault = vaultIds[_vaultId];
        return depositorVault.borrow <= maxBorrow(_vaultId);
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

}