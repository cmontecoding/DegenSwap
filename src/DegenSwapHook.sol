// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook, BeforeSwapDelta} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {VRFConsumerBaseV2Plus} from "chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract DegenSwapHook is BaseHook, ERC20, VRFConsumerBaseV2Plus {
	// Use CurrencyLibrary and BalanceDeltaLibrary
	// to add some helper functions over the Currency and BalanceDelta
	// data types 
	using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(uint256 => uint256) public requestIdToBinaryResult;
    mapping(uint256 => bool) public requestIdToBinaryResultFulfilled;

    event RequestIdFulfilled(uint256 requestId, uint256 result);
    event Claimed(uint256 requestId);

    // Your subscription ID.
    uint256 public s_subscriptionId;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/vrf/v2-5/supported-networks#configurations
    bytes32 public s_keyHash;

	// Initialize BaseHook, ERC20 and VRFV2PlusWrapperConsumerBase
    constructor(
        IPoolManager _manager,
        string memory _name,
        string memory _symbol,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    ) BaseHook(_manager) ERC20(_name, _symbol, 18) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
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
        // if the user has escrow and a pending swap then do...

        // maybe mint a 6909 to user?

        // do the underlying swap

        // take fee

        // get random number
	}

    // maybe split up half the logic to after swap?

    /**
    * @notice fulfillRandomWords handles the VRF V2 wrapper response.
    *
    * @param _requestId is the VRF V2 request ID.
    * @param _randomWords is the randomness result.
    */
    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        /// @dev this assumes only one random word was requested
        uint256 zeroOrOne = _randomWords[0] % 2;
        requestIdToBinaryResult[_requestId] = zeroOrOne;
        requestIdToBinaryResultFulfilled[_requestId] = true;
        emit RequestIdFulfilled(_requestId, zeroOrOne);

        // todo make sure this function can never revert, maybe move all extra logic to _claim function
    }

    // temp public function to test the random number generation
    function getRandomness(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        uint32 _numWords,
        bytes memory extraArgs
    ) public returns (uint256 requestId, uint256 reqPrice) {
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: _requestConfirmations,
                callbackGasLimit: _callbackGasLimit,
                numWords: _numWords,
                // Set nativePayment to true to pay for VRF requests with ETH instead of LINK
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );
    }

    function claim(uint256 _requestId) public {
        // todo somehow check this is their stuff, 6909?

        require(requestIdToBinaryResultFulfilled[_requestId] == true, "DegenSwapHook: result not ready");
        _claim(_requestId);
        emit Claimed(_requestId);
    }

    function _claim(uint256 _requestId) internal {
        uint256 result = requestIdToBinaryResult[_requestId];
        if (result == 0) {
            // they lost, transfer their remaining balance to them
        } else {
            // they won, transfer their winnings to them
        }
    }

    //todo the math/rebalancing


}