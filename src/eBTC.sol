// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {ERC20} from "../lib/solmate/src/tokens/ERC20.sol";

contract eBTC is ERC20 {
    address immutable OWNER;

    modifier onlyOnwer() {
        require(msg.sender == OWNER, "!owner");
        _;
    }

    constructor() ERC20("Ethereum Based Synthetic Bitcoin","eBTC", 18) {
        OWNER = msg.sender;
    }

    function mint(address to, uint256 amount) external onlyOnwer {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOnwer {
        _burn(from, amount);
    }
}
