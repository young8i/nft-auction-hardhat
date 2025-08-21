// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title PriceOracle 价格预言机
/// @notice 使用Chainlink feeds将ETH或ERC20的金额标准化为美元（8位小数）。
contract PriceOracle is Ownable {
    error NoFeed(address token);
    error StalePrice(address token, uint256 updatedAt, uint256 maxDelay);
    event FeedSet(address indexed token, address indexed aggregator);
    event MaxDelaySet(uint256 seconds_);

    // token -> aggregator (ETH is address(0))
    mapping(address => AggregatorV3Interface) public feeds;
    // 新鲜度检查，尽可能的保证价格稳定
    uint256 public maxDelay = 1 hours;

    constructor(address owner_) Ownable(owner_) {}

    function setFeed(address token, AggregatorV3Interface aggregator) external onlyOwner {
        feeds[token] = aggregator;
        emit FeedSet(token, address(aggregator));
    }

    function setMaxDelay(uint256 seconds_) external onlyOwner {
        maxDelay = seconds_;
        emit MaxDelaySet(seconds_);
    }

    /// @notice 返回带有8位小数的“token”的“amount”的美元值。
    function toUSD(address token, uint256 amount) public view returns (uint256 usdValue) {
        AggregatorV3Interface aggr = feeds[token];
        //如果没配置喂价，直接报错
        if (address(aggr) == address(0)) revert NoFeed(token);
        //获取最新价格
        (, int256 price,, uint256 updatedAt,) = aggr.latestRoundData();
        //如果价格太久没更新（超过 maxDelay 秒），则认为喂价过期，revert
        if (updatedAt + maxDelay < block.timestamp) revert StalePrice(token, updatedAt, maxDelay);
        // 读取该喂价的精度，价格通常有8位小数
        uint8 priceDecimals = aggr.decimals();
        //这里直接要求 必须等于 8，否则报错（为了简化处理，不考虑其他精度的情况）
        require(priceDecimals == 8, "Price decimals != 8"); 
        uint256 p = uint256(price);
        
        if (token == address(0)) {//ETH
            // ETH的数量单位是wei（1e18）
            usdValue = amount * p / 1e18;
        } else {
            uint8 d = IERC20Metadata(token).decimals();
            usdValue = amount * p / (10 ** d);
        }
    }

    /// @notice Returns price (USD, 8 decimals), updatedAt
    function getPrice(address token) external view returns (uint256, uint256) {
        AggregatorV3Interface aggr = feeds[token];
        if (address(aggr) == address(0)) revert NoFeed(token);
        (, int256 price,, uint256 updatedAt,) = aggr.latestRoundData();
        return (uint256(price), updatedAt);
    }
}
