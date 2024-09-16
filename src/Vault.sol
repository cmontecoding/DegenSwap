// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UD60x18, ud} from "lib/prb-math/src/UD60x18.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {IUniswapV2Pair} from "../src/interfaces/IUniswapV2Pair.sol";

enum RequestStatus {
    None,
    Initiated,
    Approved
}

contract Vault is IVault, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant APPROVER_ROLE = bytes32(uint256(1));
    bytes32 public constant SWAPPER_ROLE = bytes32(uint256(2));

    uint256 public constant MAX_FEE = 10_000; // in `BPS`

    // (pool => (user => (token => amount))) balances;
    mapping(address user => mapping(address token => uint256 amount)) public balances;

    // (pool => (token => amount)) totalSupply;
    mapping(address token => uint256 amount) public totalSupply;

    // (pool => (user => amount)) lpTokens;
    mapping(address user => uint256 amount) public lpTokens;

    // (pool => (user => (token => timestamp))) depositAt;
    mapping(address user => uint256 timestamp) public depositAt;

    mapping(address user => RequestStatus status) public withdrawalRequest;

    IUniswapV2Pair public immutable pair;
    uint256 public fee; // in `BPS`
    address public feeAddress;
    uint256 public minTimePeriod;

    constructor(
        address _admin,
        address _approver,
        address _hook,
        address _pair,
        uint256 _fee,
        address _feeAddress,
        uint256 _minTimePeriod
    ) {
        require(_fee <= MAX_FEE /*, InvalidFee(_fee)*/ );
        require(_pair != address(0));

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(APPROVER_ROLE, _approver);
        _grantRole(SWAPPER_ROLE, _hook);

        pair = IUniswapV2Pair(_pair);
        fee = _fee;
        feeAddress = _feeAddress;
        minTimePeriod = _minTimePeriod;
    }

    function setFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee <= MAX_FEE /*, InvalidFee(newFee)*/ );
        uint256 oldFee = fee;
        fee = newFee;

        emit ChangedFee(oldFee, newFee);
    }

    function setFeeAddress(address newFeeAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee > 0) require(newFeeAddress != address(0) /*, InvalidFeeAddress(newFeeAddress)*/ );

        address oldFeeAddress = feeAddress;
        feeAddress = newFeeAddress;

        emit ChangedFeeAddress(oldFeeAddress, newFeeAddress);
    }

    function setMinTimePeriod(uint256 newMinTimePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldMinTimePeriod = minTimePeriod;
        minTimePeriod = newMinTimePeriod;

        emit ChangedMinTimePeriod(oldMinTimePeriod, newMinTimePeriod);
    }

    function approveWithdrawalRequest(address user) external onlyRole(APPROVER_ROLE) {
        require(withdrawalRequest[user] == RequestStatus.Initiated);

        withdrawalRequest[user] = RequestStatus.Approved;
    }

    function makeWithdrawalRequest() external {
        require(withdrawalRequest[msg.sender] == RequestStatus.None);

        withdrawalRequest[msg.sender] = RequestStatus.Initiated;
    }

    function fulfillWinnings(address token, uint256 amount) external onlyRole(SWAPPER_ROLE) {
        uint256 amount0Out;
        uint256 amount1Out;
        uint256 reserveIn;
        uint256 reserveOut;
        address otherToken;

        address token0 = pair.token0();
        address token1 = pair.token1();

        (UD60x18 _reserve0, UD60x18 _reserve1,) = pair.getReserves();
        token == token0
            ? (reserveIn = _reserve0.unwrap(), reserveOut = _reserve1.unwrap())
            : (reserveIn = _reserve1.unwrap(), reserveOut = _reserve0.unwrap());
        uint256 amountOut = pair.getAmountOut(amount, reserveIn, reserveOut);

        token == token0
            ? (otherToken = token1, amount0Out = 0, amount0Out = amountOut)
            : (otherToken = token0, amount0Out = amountOut, amount0Out = 0);

        uint256 balanceBefore = IERC20(otherToken).balanceOf(address(this));

        pair.swap(amount0Out, amount1Out, address(this), "");

        uint256 balanceAfter = IERC20(otherToken).balanceOf(address(this));
        uint256 swapAmount = balanceAfter - balanceBefore;

        IERC20(otherToken).transfer(msg.sender, swapAmount);
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external {
        _addLiquidity(amount0, amount1);
    }

    function removeLiquidity(uint256 percentage) external {
        require(withdrawalRequest[msg.sender] == RequestStatus.Approved);
        require(percentage <= 10_000);

        _removeLiquidity(percentage);
    }

    function _addLiquidity(uint256 amount0, uint256 amount1) internal {
        address token0 = pair.token0();
        address token1 = pair.token1();

        uint256 amount0Pair = amount0 / 2;
        uint256 amount1Pair = amount1 / 2;

        // Add half of the tokens to the `Pair` contract
        IERC20(token0).safeTransferFrom(msg.sender, address(pair), amount0Pair);
        IERC20(token0).safeTransferFrom(msg.sender, address(pair), amount1Pair);
        uint256 _lpTokens = pair.mint(address(this));
        lpTokens[msg.sender] = _lpTokens;

        // The other half will serve as potential payouts for traders who wager
        amount0 -= amount0Pair;
        amount1 -= amount1Pair;

        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        balances[msg.sender][token0] += amount0;
        balances[msg.sender][token1] += amount1;

        totalSupply[token0] += amount0;
        totalSupply[token1] += amount1;

        depositAt[msg.sender] = block.timestamp;

        emit AddedLiquidity(msg.sender, amount0, amount1);
    }

    function _removeLiquidity(uint256 percentage) internal {
        uint256 timeDelta = block.timestamp - depositAt[msg.sender];
        require(timeDelta >= minTimePeriod /*, InsufficientAmountOfTime(timeDelta)*/ );

        address token0 = pair.token0();
        address token1 = pair.token1();

        // Cache the actual supply of the given `token`, present in the contract
        uint256 token0ActualTotalSupply = IERC20(token0).balanceOf(address(this));
        uint256 token1ActualTotalSupply = IERC20(token1).balanceOf(address(this));

        uint256 amount0 = balances[msg.sender][token0].mulDiv(percentage, 10_000);
        uint256 amount1 = balances[msg.sender][token1].mulDiv(percentage, 10_000);

        // Calculate the sum of the withdrawn `amount` and accuumulated rewards
        uint256 amount0PlusPotentialRewards = amount0.mulDiv(token0ActualTotalSupply, totalSupply[token0]);
        uint256 amount1PlusPotentialRewards = amount1.mulDiv(token1ActualTotalSupply, totalSupply[token1]);

        // Calculate the withdrawal fee
        uint256 f0 = getFee(amount0PlusPotentialRewards);
        uint256 f1 = getFee(amount1PlusPotentialRewards);

        balances[msg.sender][token0] -= amount0;
        balances[msg.sender][token1] -= amount1;
        unchecked {
            totalSupply[token0] -= amount0;
            totalSupply[token1] -= amount1;
        }

        delete depositAt[msg.sender];
        delete withdrawalRequest[msg.sender];

        uint256 lpAmount = lpTokens[msg.sender].mulDiv(percentage, IERC20(address(pair)).balanceOf(address(this)));
        lpTokens[msg.sender] -= lpAmount;

        IERC20(address(pair)).transfer(address(pair), lpAmount);
        (uint256 _amount0, uint256 _amount1) = pair.burn(address(this));

        IERC20(token0).safeTransfer(msg.sender, amount0PlusPotentialRewards + _amount0 - f0);
        IERC20(token1).safeTransfer(msg.sender, amount1PlusPotentialRewards + _amount1 - f1);

        // Transfer fee to a designated account
        if (f0 > 0) IERC20(token0).safeTransfer(feeAddress, f0);
        if (f1 > 0) IERC20(token0).safeTransfer(feeAddress, f1);

        emit RemovedLiquidity(msg.sender, amount0PlusPotentialRewards - f0, amount1PlusPotentialRewards - f1, lpAmount);
    }

    function getFee(uint256 amount) public view returns (uint256) {
        return amount * fee / MAX_FEE;
    }
}
