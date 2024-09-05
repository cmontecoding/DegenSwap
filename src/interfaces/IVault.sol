// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVault {
    function addLiquidity(address token, uint256 amount) external;
    function removeLiquidity(address token, uint256 amount, address to) external;
}
