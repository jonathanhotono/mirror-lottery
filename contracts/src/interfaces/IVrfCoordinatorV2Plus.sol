// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal Chainlink VRF v2.5 request types used by Mirror Lottery.
/// @dev ABI-compatible with @chainlink/contracts 1.5.0. Keeping the interface
///      local avoids shipping the package's unrelated legacy chain dependencies.
library VrfV2PlusClient {
    bytes4 internal constant EXTRA_ARGS_V1_TAG =
        bytes4(keccak256("VRF ExtraArgsV1"));

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function argsToBytes(ExtraArgsV1 memory extraArgs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, extraArgs);
    }
}

interface IVrfCoordinatorV2Plus {
    function requestRandomWords(
        VrfV2PlusClient.RandomWordsRequest calldata request
    ) external returns (uint256 requestId);
}
