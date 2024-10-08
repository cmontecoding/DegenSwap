// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVault {
    error InvalidFee(uint256 proposedFee);
    error InvalidFeeAddress(address proposedFeeAddress);
    error InsufficientAmountOfTime(uint256 timePassed);

    event ChangedFee(uint256 oldFee, uint256 newFee);
    event ChangedFeeAddress(address oldFeeAddress, address newFeeAddress);
    event ChangedMinTimePeriod(uint256 oldMinTimePeriod, uint256 newMinTimePeriod);
    event AddedLiquidity(address indexed user, uint256 amount0, uint256 amount1);
    event RemovedLiquidity(address indexed user, uint256 amount0, uint256 amount1, uint256 lpAmount);

    function addLiquidity(uint256 amount0, uint256 amount1) external;
    function removeLiquidity(uint256 percentage) external;
}
