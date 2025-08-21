
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal CCIP sender/receiver for cross-chain bidding.
// NOTE: This is a simplified integration to illustrate the idea and for local testing with mocks.
// On a real network, configure the Chainlink Router and tokens per CCIP docs.
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IAuctionBid {
    function bidERC20(address token, uint256 amount) external;
    function bidETH() external payable;
}

interface ICCIPRouterLike {
    function ccipSend(uint64 dstChainSelector, bytes calldata message) external payable returns (bytes32);
}

contract CrossChainGateway is Ownable {
    event Sent(uint64 dst, address auction, address token, uint256 amount, address bidder);
    event Received(uint64 src, address auction, address token, uint256 amount, address bidder);

    ICCIPRouterLike public router;
    mapping(address => bool) public allowedAuctions;

    constructor(address owner_) Ownable(owner_) {}

    function setRouter(address r) external onlyOwner {
        router = ICCIPRouterLike(r);
    }

    function allowAuction(address auction, bool allowed) external onlyOwner {
        allowedAuctions[auction] = allowed;
    }

    /// @notice Source-chain entrypoint: bridge tokens + message (off-chain router handles tokens in real CCIP)
    function sendBid(uint64 dstChainSelector, address auctionOnDst, address token, uint256 amount) external payable {
        require(allowedAuctions[auctionOnDst], "auction not allowed");
        // In real CCIP, you would transfer tokens to router with permit/approve and include the token in the message.
        bytes memory msgData = abi.encode(auctionOnDst, token, amount, msg.sender);
        router.ccipSend(dstChainSelector, msgData);
        emit Sent(dstChainSelector, auctionOnDst, token, amount, msg.sender);
    }

    /// @notice Destination-chain callback (to be called by Router in real CCIP). In tests we call it directly.
    function ccipReceive(uint64 srcChainSelector, bytes calldata data) external {
        (address auction, address token, uint256 amount, address bidder) = abi.decode(data, (address, address, uint256, address));
        require(allowedAuctions[auction], "auction not allowed");
        if (token == address(0)) {
            IAuctionBid(auction).bidETH{value: amount}();
        } else {
            // In practice, the router would deliver the bridged tokens to this contract first.
            // Here we assume tokens are already here and approved to the auction.
            IAuctionBid(auction).bidERC20(token, amount);
        }
        emit Received(srcChainSelector, auction, token, amount, bidder);
    }

    receive() external payable {}
}
