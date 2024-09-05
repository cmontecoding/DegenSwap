// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IVault} from "../src/interfaces/IVault.sol";

abstract contract Vault is IVault, Ownable2Step {
    uint256 public constant BPS = 10_000;

    // (pool => (user => (token => amount))) balances;
    mapping(address user => mapping(address token => uint256 amount)) public balances;
    mapping(address token => uint256 amount) public totalSupply;

    uint256 public fee; // bps

    constructor(address _owner, uint256 _fee) Ownable(_owner) {
        require(_fee <= BPS);
        fee = _fee;
    }

    function setFee(uint256 newFee) external onlyOwner {
        require(newFee <= BPS);
        fee = newFee;

        // emit EVENT(...);
    }

    function addLiquidity(address token, uint256 amount) external {
        _addLiquidity(token, amount);
    }

    function removeLiquidity(address token, uint256 amount) external {
        _removeLiquidity(token, amount);
    }

    function _addLiquidity(address token, uint256 amount) internal {
        // note: use `safeTransferFrom`
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        balances[msg.sender][token] += amount;
        totalSupply[token] += amount;

        //   emit EVENT(...);
    }

    function _removeLiquidity(address token, uint256 amount) internal {
        uint256 fee_ = getFee(amount);

        balances[msg.sender][token] -= amount + fee_;
        unchecked {
            totalSupply[token] -= amount;
        }

        // note: use `safeTransfer`
        IERC20(token).transfer(msg.sender, amount);

        //   emit EVENT(...);
    }

    function getFee(uint256 amount) public view returns (uint256) {
        return amount * fee / BPS;
    }
}
