// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IVault} from "../src/interfaces/IVault.sol";

abstract contract Vault is IVault, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    // (user => (pool => (token => amount))) balances;
    mapping(address user => mapping(address token => uint256 amount)) public balances;

    // (pool => (token => amount)) balances;
    mapping(address token => uint256 amount) public totalSupply;

    uint256 public fee; // bps

    constructor(address _owner, uint256 _fee) Ownable(_owner) {
        require(_fee <= BPS, InvalidFee(_fee));
        fee = _fee;
    }

    function setFee(uint256 newFee) external onlyOwner {
        require(newFee <= BPS, InvalidFee(newFee));
        uint256 oldFee = fee;
        fee = newFee;

        emit ChangedFee(oldFee, newFee);
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

        emit AddedLiquidity(msg.sender, token, amount);
    }

    function _removeLiquidity(address token, uint256 amount) internal {
        uint256 fee_ = getFee(amount);

        balances[msg.sender][token] -= amount + fee_;
        unchecked {
            totalSupply[token] -= amount;
        }

        IERC20(token).safeTransfer(msg.sender, amount);

        emit RemovedLiquidity(msg.sender, token, amount);
    }

    function getFee(uint256 amount) public view returns (uint256) {
        return amount * fee / BPS;
    }
}
