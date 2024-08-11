// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Hyperlane bridge
interface IMailbox {
    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        returns (bytes32 messageId);
}
