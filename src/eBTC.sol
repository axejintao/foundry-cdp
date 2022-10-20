// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {ERC20} from "../lib/solmate/src/tokens/ERC20.sol";

contract eBTC is ERC20 {
    address immutable OWNER;

    mapping(address => uint256) balances;

    constructor() ERC20("Ethereum Based Synthetic Bitcoin","eBTC", 18) {
        OWNER = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
