// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import "forge-std/console.sol";
import {DegenSwapHook} from "../src/DegenSwapHook.sol";
import {Vault} from "../src/Vault.sol";
import {Pair} from "../src/UniswapV2Pair.sol";

import {VRFCoordinatorV2_5Mock} from "chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract TestPointsHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    // Native tokens are represented by address(0)
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    DegenSwapHook hook;
    Vault vault;
    Pair pair;
    VRFCoordinatorV2_5Mock vrfCoordinator;
    uint256 subId;
    bytes32 keyHash = "";
    uint32 numWords = 1;
    uint32 callbackGasLimit = 400000;
    uint16 requestConfirmations = 3;

    function setUp() public {
        // Deploy VRFCoordinator
        vrfCoordinator = new VRFCoordinatorV2_5Mock(100, 100, 100);
        subId = vrfCoordinator.createSubscription();

        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();
        // Deploy 2 currencies
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo(
            "DegenSwapHook.sol",
            abi.encode(
                manager,
                address(vrfCoordinator),
                subId,
                keyHash,
                numWords,
                callbackGasLimit,
                requestConfirmations
            ),
            hookAddress
        );
        hook = DegenSwapHook(hookAddress);

        assert(Currency.unwrap(currency0) != Currency.unwrap(currency1));

        // Deploy the pair
        pair = new Pair(Currency.unwrap(currency0), Currency.unwrap(currency1));

        // Deploy the vault
        vault = new Vault(address(this), address(this), address(hook), address(pair), 0, address(this), 0);

        // set the vault in hook and pair
        hook.setVault(address(vault));
        pair.setVault(address(vault));

        (key, ) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add the hook as a consumer of the subscription
        (, , , address subOwner, ) = vrfCoordinator.getSubscription(subId);
        require(
            subOwner == address(this),
            "Subscription owner is not this contract"
        );
        vrfCoordinator.addConsumer(subId, address(hook));
        assertEq(vrfCoordinator.consumerIsAdded(subId, address(hook)), true);
    }

    function testBetZeroForOneWin() public {
        // provide lp to vault and pair
        address currency0Address = Currency.unwrap(currency0);
        address currency1Address = Currency.unwrap(currency1);
        console.log("Currency0 Address: ", currency0Address);
        console.log("Currency1 Address: ", currency1Address);
        MockERC20(currency0Address).approve(address(vault), .1 ether);
        MockERC20(currency1Address).approve(address(vault), .1 ether);
        vault.addLiquidity(.1 ether, .1 ether);

        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        bytes memory hookData = hook.getHookData(address(this), 10000);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        uint256 requestId = hook.lastRequestId();
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 1;
        vrfCoordinator.fundSubscriptionWithNative{value: 1000 ether}(subId);
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(hook), randomWords);
        assertEq(hook.requestIdToBinaryResultFulfilled(requestId), true);
        assertEq(hook.requestIdToBinaryResult(requestId), 1);

        // Input token has been deducted
        assertEq(token0BalanceAfter, token0BalanceBefore - 0.001 ether);

        // Didn't get output tokens back to user
        assertEq(token1BalanceAfter, token1BalanceBefore);

        // Hook should have received the output token
        uint256 hookToken1BalanceAfterSwap = currency1.balanceOf(address(hook));
        console.log("Hook Token1 Balance After Swap: ", hookToken1BalanceAfterSwap);
        assertGt(hookToken1BalanceAfterSwap, 0);

        hook.claim(requestId);

        uint256 token0BalanceFinal = currency0.balanceOfSelf();
        uint256 token1BalanceFinal = currency1.balanceOfSelf();

        // user should have less token0 because of their swap input
        assertEq(token0BalanceFinal, token0BalanceBefore - .001 ether);

        // user should have almost double their output token
        assertGt(token1BalanceFinal, token1BalanceBefore + .0019 ether);

        uint256 changeInBettersToken0 = token0BalanceBefore - token0BalanceFinal;
        uint256 changeInBettersToken1 = token1BalanceFinal - token1BalanceBefore;
        console.log("");
        console.log("----------------------------------");
        console.log("Better Info Below");
        console.log("Token0 Better Spent On Swap Input: ", changeInBettersToken0);
        console.log("Token1 Better Received After Claim: ", changeInBettersToken1);
        console.log("Amount Lost to Slippage (and 1 percent fees): ", .002 ether - changeInBettersToken1);
    }

     function testBetZeroForOneLoss() public {
        // provide lp to vault and pair
        address currency0Address = Currency.unwrap(currency0);
        address currency1Address = Currency.unwrap(currency1);
        console.log("Currency0 Address: ", currency0Address);
        console.log("Currency1 Address: ", currency1Address);
        MockERC20(currency0Address).approve(address(vault), .1 ether);
        MockERC20(currency1Address).approve(address(vault), .1 ether);
        vault.addLiquidity(.1 ether, .1 ether);

        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        bytes memory hookData = hook.getHookData(address(this), 10000);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        uint256 requestId = hook.lastRequestId();
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0;
        vrfCoordinator.fundSubscriptionWithNative{value: 1000 ether}(subId);
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(hook), randomWords);
        assertEq(hook.requestIdToBinaryResultFulfilled(requestId), true);
        assertEq(hook.requestIdToBinaryResult(requestId), 0);

        // Input token has been deducted
        assertEq(token0BalanceAfter, token0BalanceBefore - 0.001 ether);

        // Didn't get output tokens back to user
        assertEq(token1BalanceAfter, token1BalanceBefore);

        // Hook should have received the output token
        uint256 hookToken1BalanceAfterSwap = currency1.balanceOf(address(hook));
        console.log("Hook Token1 Balance After Swap: ", hookToken1BalanceAfterSwap);
        assertGt(hookToken1BalanceAfterSwap, 0);

        uint256 vaultToken1BalanceBeforeClaim = currency1.balanceOf(address(vault));

        hook.claim(requestId);

        uint256 token0BalanceFinal = currency0.balanceOfSelf();
        uint256 token1BalanceFinal = currency1.balanceOfSelf();

        // user should have less token0 because of their swap input
        assertEq(token0BalanceFinal, token0BalanceBefore - .001 ether);

        // user should have no more of the output token than they had before
        assertEq(token1BalanceFinal, token1BalanceBefore);

        // vault should have the output token
        uint256 vaultToken1BalanceFinal = currency1.balanceOf(address(vault));
        assertEq(vaultToken1BalanceFinal - vaultToken1BalanceBeforeClaim, hookToken1BalanceAfterSwap);

        uint256 changeInBettersToken0 = token0BalanceBefore - token0BalanceFinal;
        uint256 changeInBettersToken1 = token1BalanceFinal - token1BalanceBefore;
        console.log("");
        console.log("----------------------------------");
        console.log("Better Info Below");
        console.log("Token0 Better Spent On Swap Input: ", changeInBettersToken0);
        console.log("Token1 Better Received After Claim: ", changeInBettersToken1);
        console.log("Amount Sent To Vault (swap output): ", hookToken1BalanceAfterSwap);
    }

    function testBetOneForZeroWin() public {
        // provide lp to vault and pair
        address currency0Address = Currency.unwrap(currency0);
        address currency1Address = Currency.unwrap(currency1);
        MockERC20(currency0Address).approve(address(vault), .1 ether);
        MockERC20(currency1Address).approve(address(vault), .1 ether);
        vault.addLiquidity(.1 ether, .1 ether);

        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        bytes memory hookData = hook.getHookData(address(this), 10000);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        uint256 requestId = hook.lastRequestId();
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 1;
        vrfCoordinator.fundSubscriptionWithNative{value: 1000 ether}(subId);
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(hook), randomWords);
        assertEq(hook.requestIdToBinaryResultFulfilled(requestId), true);
        assertEq(hook.requestIdToBinaryResult(requestId), 1);

        // Input token has been deducted
        assertEq(token1BalanceAfter, token1BalanceBefore - 0.001 ether);

        // Didn't get output tokens back to user
        assertEq(token0BalanceAfter, token0BalanceBefore);

        // Hook should have received the output token
        uint256 hookToken0Balance = currency0.balanceOf(address(hook));
        console.log("Hook Token0 Balance After Swap: ", hookToken0Balance);
        assertGt(hookToken0Balance, 0);

        hook.claim(requestId);

        uint256 token1BalanceFinal = currency1.balanceOfSelf();
        uint256 token0BalanceFinal = currency0.balanceOfSelf();

        // user should have less token1 because of their swap input
        assertEq(token1BalanceFinal, token1BalanceBefore - .001 ether);

        // user should have almost double their output token
        assertGt(token0BalanceFinal, token0BalanceBefore + .0019 ether);

        uint256 changeInBettersToken1 = token1BalanceBefore - token1BalanceFinal;
        uint256 changeInBettersToken0 = token0BalanceFinal - token0BalanceBefore;
        console.log("");
        console.log("----------------------------------");
        console.log("Better Info Below");
        console.log("Token1 Better Spent On Swap Input: ", changeInBettersToken1);
        console.log("Token0 Better Received After Claim: ", changeInBettersToken0);
        console.log("Amount Lost to Slippage (and 1 percent fees): ", .002 ether - changeInBettersToken0);
    }

    function testAfterSwap() public {
        // provide lp to vault and pair
        address currency0Address = Currency.unwrap(currency0);
        address currency1Address = Currency.unwrap(currency1);
        MockERC20(currency0Address).approve(address(vault), .1 ether);
        MockERC20(currency1Address).approve(address(vault), .1 ether);
        vault.addLiquidity(.1 ether, .1 ether);

        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        bytes memory hookData = hook.getHookData(address(this), 10000);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        // Input token has been deducted
        assertEq(token0BalanceAfter, token0BalanceBefore - 0.001 ether);

        // Didn't get output tokens back to user
        assertEq(token1BalanceAfter, token1BalanceBefore);

        // Hook should have received the output token
        uint256 hookToken1BalanceAfterSwap = currency1.balanceOf(address(hook));
        console.log("Hook Token1 Balance After Swap: ", hookToken1BalanceAfterSwap);
        assertGt(hookToken1BalanceAfterSwap, 0);
    }

    /// @notice test that an exact output swap will not execute the hook
    /// and will be a normal swap
    function testAfterSwapExactOutputToken1() public {
        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: .001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        // Output token is exact
        assertEq(token1BalanceAfter, token1BalanceBefore + .001 ether);

        // Input token was extracted
        assertLt(token0BalanceAfter, token0BalanceBefore);
    }

    /// @notice test that an exact output swap will not execute the hook
    /// and will be a normal swap
    function testAfterSwapExactOutputToken0() public {
        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: .001 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        // Input token has been deducted
        assertLt(token1BalanceAfter, token1BalanceBefore);

        // Did get exact output tokens back to user
        assertEq(token0BalanceAfter, token0BalanceBefore + .001 ether);
    }
}
