// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UD60x18} from "lib/prb-math/src/UD60x18.sol";

interface IUniswapV2Pair {
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(UD60x18 reserve0, UD60x18 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (UD60x18 reserve0, UD60x18 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}
