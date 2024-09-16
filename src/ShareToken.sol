// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20Permit, ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title An ERC20Permit token contract
 * @author Georgi Chonkov
 * @notice You can use this contract for basic simulations
 */
contract ShareToken is Ownable, ERC20Permit {
    event ShareTokenMinted(address, uint256);
    event ShareTokenBurned(address, uint256);

    string public constant NAME = "ShareToken";
    string public constant SYMBOL = "STKN";

    /**
     *  @notice {EIP2612} `name` and {EIP20} `name` MUST be the same
     *  @dev Initializes the {EIP2612} `name` and {EIP20} `name` & `symbol`
     */
    constructor() Ownable(_msgSender()) ERC20Permit(NAME) ERC20(NAME, SYMBOL) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit ShareTokenMinted(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
        emit ShareTokenBurned(from, amount);
    }
}
