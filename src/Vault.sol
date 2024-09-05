// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IVault} from "../src/interfaces/IVault.sol";

abstract contract Vault is IVault {
    // (pool => (user => (token => amount))) balances;
    mapping(address user => mapping(address token => uint256 amount)) public balances;

    function addLiquidity(address token, uint256 amount) external {
        _addLiquidity(token, amount);
    }

    function removeLiquidity(address token, uint256 amount, address to) external {
        _removeLiquidity(token, to, amount);
    }

    function _addLiquidity(address token, uint256 amount) internal {
        // note: use `safeTransferFrom`
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balances[msg.sender][token] += amount;

        //   emit EVENT(...);
    }

    function _removeLiquidity(address token, address to, uint256 amount) internal {
        balances[msg.sender][token] -= amount;

        // note: use `safeTransfer`
        IERC20(token).transfer(to, amount);

        //   emit EVENT(...);
    }
}
