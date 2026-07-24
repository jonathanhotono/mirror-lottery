// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {VrfV2PlusClient} from
    "../interfaces/IVrfCoordinatorV2Plus.sol";

interface IVrfConsumer {
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external;
}

contract MockVrfCoordinator {
    error UnknownRequest();

    uint256 public nextRequestId = 1;
    mapping(uint256 requestId => address consumer) public consumerForRequest;

    function requestRandomWords(
        VrfV2PlusClient.RandomWordsRequest calldata
    ) external returns (uint256 requestId) {
        requestId = nextRequestId;
        ++nextRequestId;
        consumerForRequest[requestId] = msg.sender;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        address consumer = consumerForRequest[requestId];
        if (consumer == address(0)) revert UnknownRequest();
        delete consumerForRequest[requestId];

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomWord;
        IVrfConsumer(consumer).rawFulfillRandomWords(
            requestId,
            randomWords
        );
    }
}
