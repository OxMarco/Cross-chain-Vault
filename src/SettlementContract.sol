// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ISettlementContract} from "./interfaces/ISettlementContract.sol";
import {IMailbox} from "./interfaces/IMailbox.sol";

contract SettlementContract is ISettlementContract {
    using SafeERC20 for IERC20;

    IMailbox public immutable mailbox;
    uint256 public immutable chainId;
    mapping(bytes32 => bool) public filledOrders;

    constructor(address _mailbox) {
        mailbox = IMailbox(_mailbox);
        chainId = block.chainid;
    }

    error FailedIntent();
    error OrderNotFilled();

    /// @notice Initiates the settlement of a cross-chain order
    /// @dev To be called by the filler
    /// @dev Transfers the swapper's input tokens to the contract, later to be claimed by the solver
    /// @param order The CrossChainOrder definition
    /// @param signature The swapper's signature over the order
    function initiate(CrossChainOrder memory order, bytes calldata signature) external {
        (ResolvedCrossChainOrder memory crossChainOrder) = abi.decode(order.orderData, (ResolvedCrossChainOrder));

        bytes32 orderHash = keccak256(abi.encode(order));
        (address recoveredAddress,,) = ECDSA.tryRecover(orderHash, signature);
        assert(recoveredAddress == order.swapper);

        for (uint256 i = 0; i < crossChainOrder.swapperInputs.length; i++) {
            IERC20 token = IERC20(crossChainOrder.swapperInputs[i].token);
            token.safeTransferFrom(order.swapper, address(this), crossChainOrder.swapperInputs[i].amount);
        }
    }

    /// @notice Resolves a specific CrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The CrossChainOrder definition
    function resolve(CrossChainOrder memory order) public pure returns (ResolvedCrossChainOrder memory) {
        // Decode the orderData to retrieve the input, output, and filler output information.
        (Input[] memory swapperInputs, Output[] memory swapperOutputs, Output[] memory fillerOutputs) =
            abi.decode(order.orderData, (Input[], Output[], Output[]));

        // Construct the ResolvedCrossChainOrder struct using the provided order and decoded data.
        ResolvedCrossChainOrder memory resolvedOrder = ResolvedCrossChainOrder({
            settlementContract: order.settlementContract,
            swapper: order.swapper,
            nonce: order.nonce,
            originChainId: order.originChainId,
            initiateDeadline: order.initiateDeadline,
            fillDeadline: order.fillDeadline,
            swapperInputs: swapperInputs,
            swapperOutputs: swapperOutputs,
            fillerOutputs: fillerOutputs
        });

        return resolvedOrder;
    }

    /// @notice Resolves a specific CrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The CrossChainOrder definition
    /// @param fillerData Any filler-defined data required by the settler
    function fill(CrossChainOrder memory order, bytes memory fillerData)
        external
        returns (ResolvedCrossChainOrder memory)
    {
        ResolvedCrossChainOrder memory crossChainOrder = resolve(order);

        Input[] memory state = _snapshotCurrentState(crossChainOrder.swapperOutputs);

        (SolutionSegment[] memory segments, address destination) = abi.decode(fillerData, (SolutionSegment[], address));

        for (uint256 i = 0; i < segments.length; i++) {
            SolutionSegment memory segment = segments[i];

            (bool success,) = payable(segment.to).call{value: segment.value}(segment.data);

            if (!success) {
                revert FailedIntent();
            }
        }

        _validateSolution(state, crossChainOrder.swapperOutputs);

        // send message back to origin chain
        bytes32 _hash = keccak256(abi.encode(order)); // true represents a non filled order

        mailbox.dispatch(order.originChainId, _addressToBytes32(destination), abi.encode(_hash));
    
        return crossChainOrder;
    }

    function _snapshotCurrentState(Output[] memory outputs) internal view returns (Input[] memory state) {
        for (uint256 i = 0; i < outputs.length; i++) {
            ERC20 token = ERC20(outputs[i].token);

            uint256 balance = token.balanceOf(outputs[i].recipient);
            state[i] = Input(outputs[i].token, balance);
        }
    }

    function _validateSolution(Input[] memory state, Output[] memory outputs) internal view {
        for (uint256 i = 0; i < outputs.length; i++) {
            ERC20 token = ERC20(outputs[i].token);

            uint256 diff = token.balanceOf(outputs[i].recipient) - state[i].amount;
            require(diff >= outputs[i].amount);
        }
    }

    function claim(CrossChainOrder memory order) public {
        bytes32 orderHash = keccak256(abi.encode(order));

        if (!filledOrders[orderHash]) revert OrderNotFilled();

        ResolvedCrossChainOrder memory crossChainOrder = resolve(order);

        for (uint256 i = 0; i < crossChainOrder.fillerOutputs.length; i++) {
            Output memory output = crossChainOrder.fillerOutputs[i];

            ERC20 token = ERC20(output.token);
            token.transfer(output.recipient, output.amount);
        }

        delete filledOrders[orderHash];
    }

    function handle(bytes calldata _data) external payable {
        bytes32 _hash = abi.decode(_data, (bytes32));
        filledOrders[_hash] = true;
    }

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
