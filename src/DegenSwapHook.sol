// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook, BeforeSwapDelta} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract DegenSwapHook is BaseHook, ERC20 {
	// Use CurrencyLibrary and BalanceDeltaLibrary
	// to add some helper functions over the Currency and BalanceDelta
	// data types 
	using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

	// Initialize BaseHook and ERC20
    constructor(
        IPoolManager _manager,
        string memory _name,
        string memory _symbol
    ) BaseHook(_manager) ERC20(_name, _symbol, 18) {}

	// Set up hook permissions to return `true`
	// for the two hook functions we are using
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

	// Stub implementation of `beforeSwap`
	function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        
	}
}