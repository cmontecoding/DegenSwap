// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

    // (pool => (token => totalRewardPerToken)) totalRewardPerToken;
    mapping(address token => int256 totalRewardPerToken) totalRewardPerToken;

    // (pool => (user => (token => userRewardPerToken))) userRewardPerToken;
    mapping(address user => mapping(address token => int256 userRewardPerToken)) userRewardPerToken;

    IUniswapV2Pair public immutable pair;
    uint256 public fee; // in `BPS`
    address public feeAddress;
    uint256 public minTimePeriod;

    constructor(
        address _admin,
        address _approver,
        address _pair,
        uint256 _fee,
        address _feeAddress,
        uint256 _minTimePeriod
    ) {
        require(_fee <= MAX_FEE /*, InvalidFee(_fee)*/ );
        require(_pair != address(0));

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(APPROVER_ROLE, _approver);

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

    function addLiquidity(uint256 amount0, uint256 amount1) external {
        _addLiquidity(amount0, amount1);
    }

    function removeLiquidity(address token, uint256 amount) external {
        require(withdrawalRequest[msg.sender] == RequestStatus.Approved);

        _removeLiquidity(token, amount);
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

    function _removeLiquidity(address token, uint256 amount) internal {
        uint256 timeDelta = block.timestamp - depositAt[msg.sender];
        require(timeDelta >= minTimePeriod /*, InsufficientAmountOfTime(timeDelta)*/ );

        // Calculate the withdrawal fee for the given `amount`
        uint256 f = getFee(amount);

        // Cache the actual supply of the given `token`, present in the contract
        uint256 actualTotalSupply = IERC20(token).balanceOf(address(this));

        // Calculate the sum of the withdrawn `amount` and accuumulated rewards
        uint256 amountPlusRewards = amount.mulDiv(actualTotalSupply, totalSupply[token]);

        /*
        uint256 balance = balances[msg.sender][token];
        int256 _userRewardPerToken = userRewardPerToken[msg.sender][token];
        int256 _totalRewardPerToken = totalRewardPerToken[token];
        int256 reward = balance * (_totalRewardPerToken - _userRewardPerToken);
        uint256 amountPlusUserReward = balance + reward;
        */

        balances[msg.sender][token] -= amount;
        unchecked {
            totalSupply[token] -= amount;
        }

        delete depositAt[msg.sender];

        IERC20(token).safeTransfer(msg.sender, amountPlusRewards - f);

        // Transfer fee to a designated account
        if (f > 0) IERC20(token).safeTransfer(feeAddress, f);

        emit RemovedLiquidity(msg.sender, token, amount);
    }

    function getFee(uint256 amount) public view returns (uint256) {
        return amount * fee / MAX_FEE;
    }
}
