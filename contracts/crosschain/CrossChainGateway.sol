// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// CCIP 跨链竞价发送/接收合约。
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

    /// @notice 源链入口函数：桥接代币 + 消息（在真实 CCIP 中由链下 Router 处理代币）
    function sendBid(uint64 dstChainSelector, address auctionOnDst, address token, uint256 amount) external payable {
        require(allowedAuctions[auctionOnDst], "auction not allowed");
        // 在真实 CCIP 中，你需要先将代币转给 router（使用 permit/approve），并把代币信息包含在消息里。
        bytes memory msgData = abi.encode(auctionOnDst, token, amount, msg.sender);
        router.ccipSend(dstChainSelector, msgData);
        emit Sent(dstChainSelector, auctionOnDst, token, amount, msg.sender);
    }

    /// @notice 目标链回调函数（在真实 CCIP 中由 Router 调用，在测试中我们直接调用）。
    function ccipReceive(uint64 srcChainSelector, bytes calldata data) external {
        (address auction, address token, uint256 amount, address bidder) = abi.decode(data, (address, address, uint256, address));
        require(allowedAuctions[auction], "auction not allowed");
        if (token == address(0)) {
            IAuctionBid(auction).bidETH{value: amount}();
        } else {
            // 实际上，router 会先把桥接过来的代币转到本合约。
            // 在这里我们假设代币已经在本合约，并且已经授权给 auction。
            IAuctionBid(auction).bidERC20(token, amount);
        }
        emit Received(srcChainSelector, auction, token, amount, bidder);
    }

    receive() external payable {}
}
