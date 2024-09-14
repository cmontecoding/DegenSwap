// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook, BeforeSwapDelta} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC6909} from "v4-core/ERC6909.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {VRFConsumerBaseV2Plus} from "chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract DegenSwapHook is BaseHook, ERC6909, VRFConsumerBaseV2Plus {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(uint256 => uint256) public requestIdToBinaryResult;
    mapping(uint256 => bool) public requestIdToBinaryResultFulfilled;
    mapping(uint256 => bool) public requestIdToBinaryResultClaimed; //todo maybe combine this and the above into an enum. or all 3 into struct

    event RequestIdFulfilled(uint256 requestId, uint256 result);
    event Claimed(uint256 requestId);

    // Your subscription ID.
    uint256 public s_subscriptionId;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/vrf/v2-5/supported-networks#configurations
    bytes32 public s_keyHash;

    uint32 public randomnessNumWords;
    uint32 public randomnessCallbackGasLimit;
    uint16 public randomnessRequestConfirmations;

    // Initialize BaseHook and VRFV2PlusWrapperConsumerBase
    constructor(
        IPoolManager _manager,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _randomnessNumWords,
        uint32 _randomnessCallbackGasLimit,
        uint16 _randomnessRequestConfirmations
    )
        BaseHook(_manager)
        VRFConsumerBaseV2Plus(_vrfCoordinator)
    {
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
        randomnessNumWords = _randomnessNumWords;
        randomnessCallbackGasLimit = _randomnessCallbackGasLimit;
        randomnessRequestConfirmations = _randomnessRequestConfirmations;
    }

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
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        /// @dev we only execute the hook if this is an exact input swap
        /// (exact output swaps will just be normal swaps)
        if (params.amountSpecified > 0) return (this.afterSwap.selector, 0);
        
        int128 hookDeltaUnspecified = params.zeroForOne
            ? delta.amount1()
            : delta.amount0();

        Currency currency = params.zeroForOne ? key.currency1 : key.currency0;

        poolManager.take(
            currency,
            address(this),
            uint256(int256(hookDeltaUnspecified))
        );

        /// @dev get random number
        (uint256 requestId, uint256 reqPrice) = _getRandomness();

        /// @dev mint 6909 claim token
        _mint(msg.sender, currency.toId(), uint256(int256(hookDeltaUnspecified))); //todo make not msg.sender

        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    /**
     * @notice fulfillRandomWords handles the VRF V2 wrapper response.
     *
     * @param _requestId is the VRF V2 request ID.
     * @param _randomWords is the randomness result.
     */
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        /// @dev this assumes only one random word was requested
        uint256 zeroOrOne = _randomWords[0] % 2;
        requestIdToBinaryResult[_requestId] = zeroOrOne;
        requestIdToBinaryResultFulfilled[_requestId] = true;
        // todo make sure this function can never revert, maybe move all extra logic to _claim function
    }

    /**
     * @notice _getRandomness requests randomness from the VRF V2 coordinator.
     *
     * @return requestId is the VRF V2 request ID.
     * @return reqPrice is the VRF V2 request price.
     */
    function _getRandomness() internal returns (uint256 requestId, uint256 reqPrice) { 
        //todo add the second return value
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: randomnessRequestConfirmations,
                callbackGasLimit: randomnessCallbackGasLimit,
                numWords: randomnessNumWords,
                // Set nativePayment to true to pay for VRF requests with ETH instead of LINK
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: true}) //todo maybe make this adjustable, currently hardcoded to eth
                )
            })
        );
    }

    //todo maybe just check the 6909 based off a mapping of requestId ==> 6909
    function claim(uint256 _requestId, uint256 id, uint256 amount) public {
        // todo somehow check this is their stuff, 6909?
        require(
            requestIdToBinaryResultClaimed[_requestId] == false,
            "DegenSwapHook: already claimed"
        );
        require(
            requestIdToBinaryResultFulfilled[_requestId] == true,
            "DegenSwapHook: result not ready"
        );
        _claim(_requestId, id, amount);
        emit Claimed(_requestId);
    }

    function _claim(uint256 _requestId, uint256 id, uint256 amount) internal {
        uint256 result = requestIdToBinaryResult[_requestId];
        // todo get the % they want to gamble
        // todo take the fee (likely 1% and likely before applying gambling odds)
        if (result == 0) {
            /// @dev user lost, transfer their remaining balance to them

            // burn claim token
        } else if (result == 1) {
            /// @dev user won, transfer their winnings to them

            // burn claim token
        }
        requestIdToBinaryResultClaimed[_requestId] = true;
    }

    function setRandomnessNumWords(uint32 _randomnessNumWords) public {
        randomnessNumWords = _randomnessNumWords;
    }

    function setRandomnessCallbackGasLimit(uint32 _randomnessCallbackGasLimit) public {
        randomnessCallbackGasLimit = _randomnessCallbackGasLimit;
    }

    function setRandomnessRequestConfirmations(uint16 _randomnessRequestConfirmations) public {
        randomnessRequestConfirmations = _randomnessRequestConfirmations;
    }

    function setSubscriptionId(uint256 _subscriptionId) public {
        s_subscriptionId = _subscriptionId;
    }

    function setKeyHash(bytes32 _keyHash) public {
        s_keyHash = _keyHash;
    }

    //todo the math/rebalancing
}
