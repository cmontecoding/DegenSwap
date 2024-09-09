// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IVault} from "../src/interfaces/IVault.sol";

contract Vault is IVault, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant MAX_FEE = 10_000; // in `BPS`

    // (user => (pool => (token => amount))) balances;
    mapping(address user => mapping(address token => uint256 amount)) public balances;

    // (pool => (token => amount)) balances;
    mapping(address token => uint256 amount) public totalSupply;

    // (user => (pool => (token => timestamp))) depositAt;
    mapping(address user => mapping(address token => uint256 timestamp)) public depositAt;

    uint256 public fee; // in `BPS`
    address public feeAddress;
    uint256 public minTimePeriod;

    constructor(address _owner, uint256 _fee, address _feeAddress, uint256 _minTimePeriod) Ownable(_owner) {
        require(_fee <= MAX_FEE, InvalidFee(_fee));
        fee = _fee;
        feeAddress = _feeAddress;
        minTimePeriod = _minTimePeriod;
    }

    function setFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, InvalidFee(newFee));
        uint256 oldFee = fee;
        fee = newFee;

        emit ChangedFee(oldFee, newFee);
    }

    function setFeeAddress(address newFeeAddress) external onlyOwner {
        if (fee > 0) require(newFeeAddress != address(0), InvalidFeeAddress(newFeeAddress));

        address oldFeeAddress = feeAddress;
        feeAddress = newFeeAddress;

        emit ChangedFeeAddress(oldFeeAddress, newFeeAddress);
    }

    function setMinTimePeriod(uint256 newMinTimePeriod) external onlyOwner {
        uint256 oldMinTimePeriod = minTimePeriod;
        minTimePeriod = newMinTimePeriod;

        emit ChangedMinTimePeriod(oldMinTimePeriod, newMinTimePeriod);
    }

    function addLiquidity(address token, uint256 amount) external {
        _addLiquidity(token, amount);
    }

    function removeLiquidity(address token, uint256 amount) external {
        _removeLiquidity(token, amount);
    }

    function _addLiquidity(address token, uint256 amount) internal {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[msg.sender][token] += amount;
        totalSupply[token] += amount;
        depositAt[msg.sender][token] = block.timestamp;

        emit AddedLiquidity(msg.sender, token, amount);
    }

    function _removeLiquidity(address token, uint256 amount) internal {
        uint256 timeDelta = block.timestamp - depositAt[msg.sender][token];
        require(timeDelta >= minTimePeriod, InsufficientAmountOfTime(timeDelta));

        // Calculate the withdrawal fee for the given `amount`
        uint256 f = getFee(amount);

        // Cache the actual supply of the given `token`, present in the contract
        uint256 actualTotalSupply = IERC20(token).balanceOf(address(this));

        // Calculate the sum of the withdrawn `amount` and accuumulated rewards
        uint256 amountPlusRewards = amount.mulDiv(actualTotalSupply, totalSupply[token]);

        balances[msg.sender][token] -= amount;
        unchecked {
            totalSupply[token] -= amount;
        }

        delete depositAt[msg.sender][token];

        IERC20(token).safeTransfer(msg.sender, amountPlusRewards - f);

        // Transfer fee to a designated account
        if (f > 0) IERC20(token).safeTransfer(feeAddress, f);

        emit RemovedLiquidity(msg.sender, token, amount);
    }

    function getFee(uint256 amount) public view returns (uint256) {
        return amount * fee / MAX_FEE;
    }
}
