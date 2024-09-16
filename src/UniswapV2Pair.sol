// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC3156FlashLender} from "lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "lib/openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {UD60x18, ud, MAX_WHOLE_UD60x18} from "lib/prb-math/src/UD60x18.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {ShareToken} from "./ShareToken.sol";

contract Pair is IUniswapV2Pair, Context, ERC165, IERC3156FlashLender, ShareToken, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Pair_Locked();
    error Pair_Invalid_Out_Amounts();
    error Pair_Invalid_In_Amounts();
    error Pair_Insufficient_Liquidity();
    error Pair_Insufficient_Liquidity_Minted();
    error Pair_Insufficient_Liquidity_Burned();
    error Pair_Overflow();
    error Pair_Invalid_Receiver();
    error Pair_Invalid_K();
    error Pair_Invalid_IERC3156FlashBorrower();
    error Pair_Invalid_Token();
    error Pair_Invalid_Callback();

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable token0;
    address public immutable token1;
    address public vault;

    UD60x18 private reserve0;
    UD60x18 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @dev Updates the reserves and accumulated prices since the last swap/mint/burn
     * @param balance0 Actual amount of the first token in the pool.
     * @param balance1 Actual amount of the second token in the pool.
     * @param _reserve0 Current reserve/amount of the first token in the pool.
     * @param _reserve1 Current reserve/amount of the second token in the pool.
     */
    function _update(uint256 balance0, uint256 balance1, uint256 _reserve0, uint256 _reserve1) private {
        if (UD60x18.wrap(balance0) > MAX_WHOLE_UD60x18 || UD60x18.wrap(balance1) > MAX_WHOLE_UD60x18) {
            revert Pair_Overflow();
        }

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            UD60x18 udReserve0 = ud(_reserve0);
            UD60x18 udReserve1 = ud(_reserve1);

            unchecked {
                price0CumulativeLast += udReserve1.div(udReserve0).unwrap() * timeElapsed;
                price1CumulativeLast += udReserve0.div(udReserve1).unwrap() * timeElapsed;
            }
        }

        reserve0 = UD60x18.wrap(balance0);
        reserve1 = UD60x18.wrap(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(reserve0, reserve1);
    }

    /**
     * @dev Determine whether the fee is on and send tokens to the recipient address
     * @param _reserve0 Current reserve/amount of the first token in the pool.
     * @param _reserve1 Current reserve/amount of the second token in the pool.
     * @return feeOn Returns whether or not the fee is turned on.
     */
    function _mintFee(UD60x18 _reserve0, UD60x18 _reserve1) private returns (bool feeOn) {
        address feeTo = address(0);
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;

        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(_reserve0.unwrap() * _reserve1.unwrap());
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * uint256(rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
     * @dev Sends liquidity tokens to the address providing liquidity to the pool.
     * @param to The receiver of the liquidity/share tokens.
     * @return liquidity Returns the amount of minted tokens.
     */
    function mint(address to) external nonReentrant onlyVault returns (uint256 liquidity) {
        (UD60x18 _reserve0, UD60x18 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0.unwrap();
        uint256 amount1 = balance1 - _reserve1.unwrap();

        bool feeOn = _mintFee(_reserve0, _reserve1);

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity =
                Math.min((amount0 * _totalSupply) / _reserve0.unwrap(), (amount1 * _totalSupply) / _reserve1.unwrap());

            // UD60x18 ratio0 = UD60x18.wrap(amount0).div(_reserve0);
            // UD60x18 ratio1 = UD60x18.wrap(amount1).div(_reserve1);

            // if (ratio0 != ratio1) revert Pair_Invalid_Ratio();
        }
        if (liquidity == 0) revert Pair_Insufficient_Liquidity_Minted();
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0.unwrap(), _reserve1.unwrap());
        if (feeOn) kLast = reserve0.unwrap() * reserve1.unwrap();

        emit Mint(_msgSender(), amount0, amount1);
    }

    /**
     * @dev Sends back the tokens of the liquidity provider by `burning` the transfered tokens representing his/her portion of the pool.
     * @param to The receiver of the tokens.
     * @return amount0 The amount of the first returned back.
     * @return amount1 The amount of the second returned back.
     */
    function burn(address to) external nonReentrant onlyVault returns (uint256 amount0, uint256 amount1) {
        (UD60x18 _reserve0, UD60x18 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (liquidity * balance1) / _totalSupply; // using balances ensures pro-rata distribution

        if (amount0 == 0 || amount1 == 0) revert Pair_Insufficient_Liquidity_Burned();

        _burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0.unwrap(), _reserve1.unwrap());
        if (feeOn) kLast = reserve0.unwrap() * reserve1.unwrap(); // reserve0 and reserve1 are up-to-date

        emit Burn(_msgSender(), amount0, amount1, to);
    }

    /**
     * @dev Transfer tokens to receiver `preserving` the `constant` after the swap is completed.
     * @param amount0Out Amount of the first of the pair of tokens to transfer.
     * @param amount1Out Amount of the second of the pair of tokens to transfer.
     * @param to The receiver of the tokens.
     */
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata /* data */ )
        external
        nonReentrant
        onlyVault
    {
        // Example:
        // token0 = ETH, token1 = DAI
        // Before swap is made and no tokens are transfered: reserve0 = 10 ETH, reserve1 = 10,000 DAI => K = 100,000
        // Before `swap` is called - user calls 'transfer' and sends 2,5 ETH => reserve0 = 12,5 ETH => amount0Out = 0 && amount1Out = 2,000
        // amount1Out = reserve1 - K / reserve0' (reserve0' = reserve0 + 2,5 ETH = 12,5 ETH)

        if (amount0Out == 0 && amount1Out == 0) revert Pair_Invalid_Out_Amounts();
        (UD60x18 _reserve0, UD60x18 _reserve1,) = getReserves();

        if (amount0Out >= _reserve0.unwrap() || amount1Out >= _reserve1.unwrap()) revert Pair_Insufficient_Liquidity();

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            if (to == token0 || to == token1) revert Pair_Invalid_Receiver();

            if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
            if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
            // if (data.length > 0) ICallee(to).uniswapV2Call(_msgSender(), amount0Out, amount1Out, data); // 'FlashSwap'
            balance0 = IERC20(token0).balanceOf(address(this));
            balance1 = IERC20(token1).balanceOf(address(this));
        }

        // 12,5 ETH > 10 ETH - 0 (amount0Out = 0) => amount0In = 2,5 ETH
        uint256 amount0In =
            balance0 > _reserve0.unwrap() - amount0Out ? balance0 - (_reserve0.unwrap() - amount0Out) : 0;
        // 8,000 DAI > 10,000 DAI - 2,000 DAI (amount0Out = 2,000) => amount1In = 0
        uint256 amount1In =
            balance1 > _reserve1.unwrap() - amount1Out ? balance1 - (_reserve1.unwrap() - amount1Out) : 0;

        if (amount0In == 0 && amount1In == 0) revert Pair_Invalid_In_Amounts();
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint256 balance0Adjusted = balance0 * 1000 - amount0In * 10;
            uint256 balance1Adjusted = balance1 * 1000 - amount1In * 10;
            // (12,5 - dx(amount0In * 10))*(8,000) >= 10 * 10,000, but dx has been already paid as a fee
            if (balance0Adjusted * balance1Adjusted < _reserve0.unwrap() * _reserve1.unwrap() * 1000 ** 2) {
                revert Pair_Invalid_K();
            }
        }

        _update(balance0, balance1, _reserve0.unwrap(), _reserve1.unwrap());
        emit Swap(_msgSender(), amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @dev Sends extra tokens to an address the reserves by correctly updating them if tokens were directly sent
     * @param to Address to receive extra tokens
     */
    function skim(address to) external nonReentrant onlyVault {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0.unwrap());
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1.unwrap());
    }

    /**
     * @dev Syncs the reserves by correctly updating them if tokens were directly sent
     */
    function sync() external nonReentrant onlyVault {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0.unwrap(),
            reserve1.unwrap()
        );
    }

    /**
     * @dev Loan `amount` tokens to `receiver`, and takes it back plus a `flashFee` after the callback.
     * @param receiver The contract receiving the tokens, needs to implement the `onFlashLoan(address user, uint256 amount, uint256 fee, bytes calldata)` interface.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param data A data parameter to be passed on to the `receiver` for any custom use.
     */
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        nonReentrant
        returns (bool)
    {
        // "Receiver must implement IERC3156FlashBorrower interafce."
        if (!(ERC165(address(receiver)).supportsInterface(type(IERC3156FlashBorrower).interfaceId))) {
            revert Pair_Invalid_IERC3156FlashBorrower();
        }

        //  "FlashLender: Unsupported currency"
        if (token != token0 && token != token1) revert Pair_Invalid_Token();

        uint256 calculatedLoanFee = flashFee(token, amount);

        IERC20(token).safeTransfer(address(receiver), amount);

        // "FlashLender: Callback failed"
        if (receiver.onFlashLoan(_msgSender(), token, amount, calculatedLoanFee, data) != CALLBACK_SUCCESS) {
            revert Pair_Invalid_Callback();
        }

        IERC20(token).safeTransferFrom(address(receiver), address(this), amount + calculatedLoanFee);

        (UD60x18 _reserve0, UD60x18 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0.unwrap(), _reserve1.unwrap());

        return true;
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @notice Makes a check and returns zero -> no fee is charged.
     * @param token The loan currency.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 /* amount */ ) public view override returns (uint256) {
        //  "FlashLender: Unsupported currency"
        if (token != token0 && token != token1) revert();
        return 0;
    }

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view override returns (uint256) {
        return token == token0
            ? IERC20(token0).balanceOf(address(this))
            : token == token1 ? IERC20(token1).balanceOf(address(this)) : 0;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IERC3156FlashLender).interfaceId || super.supportsInterface(interfaceId);
    }

    function getReserves() public view returns (UD60x18 _reserve0, UD60x18 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function setVault(address _vault) public {
        if (vault != address(0)) {
            revert("DegenSwapHook: vault already set");
        }
        vault = _vault;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 990;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    modifier onlyVault() {
        require(_msgSender() == vault);
        _;
    }
}
