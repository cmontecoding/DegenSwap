// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVault {
    error InvalidFee(uint256 proposedFee);

    event ChangedFee(uint256 oldFee, uint256 newFee);
    event AddedLiquidity(address indexed user, address indexed token, uint256 amount);
    event RemovedLiquidity(address indexed user, address indexed token, uint256 amount);

    function addLiquidity(address token, uint256 amount) external;
    function removeLiquidity(address token, uint256 amount) external;
}
