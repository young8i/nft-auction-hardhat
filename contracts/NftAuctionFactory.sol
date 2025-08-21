// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {PriceOracle} from "./PriceOracle.sol";

interface IAuction {
    function initialize(
        address factory_,
        address seller_,
        address nft_,
        uint256 tokenId_,
        uint64 startTime_,
        uint64 endTime_,
        uint256 startPriceUsd_,
        address oracle_
    ) external;
}

contract NftAuctionFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    event AuctionCreated(address indexed auction, address indexed nft, uint256 indexed tokenId, address seller);
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event FeeToSet(address indexed feeTo);
    event FeeTiersSet(uint256[] usdThresholds, uint16[] bps);

    //拍卖实现合约地址
    address public auctionImplementation;
    //喂价合约
    PriceOracle public oracle;
    //手续费接收地址
    address public feeTo;

    // 计费表: for bidUSD >= thresholds[i], use bps[i]
    uint256[] public usdThresholds; // USD with 8 decimals
    uint16[] public bps; // fee in basis points

    mapping(bytes32 => address) public auctionOf; // key(nft, tokenId) -> auction
    address[] public allAuctions;

    function initialize(address owner_, address implementation_, address oracle_, address feeTo_) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        auctionImplementation = implementation_;
        oracle = PriceOracle(oracle_);
        feeTo = feeTo_;
        //  < $100 => 200 bps, >= $1000 => 150 bps, >= $10k => 100 bps
        usdThresholds = [uint256(1_0000_0000), uint256(1000_0000_0000), uint256(10_000_0000_0000)]; // 100, 1k, 10k (8 decimals)
        // 存放的是 费率，用 基点 (basis points, bps) 表示
        bps = [uint16(200), 150, 100]; //2.00%、1.50%、1.00%
    }

    //限制仅合约所有者有升级权限
    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}

    //可更新实现合约
    function setImplementation(address newImpl) external onlyOwner {
        emit ImplementationUpdated(auctionImplementation, newImpl);
        auctionImplementation = newImpl;
    }

    //设置手续费接收地址
    function setFeeTo(address newFeeTo) external onlyOwner {
        feeTo = newFeeTo;
        emit FeeToSet(newFeeTo);
    }

    //设置分级费率表
    function setFeeTiers(uint256[] calldata thresholds, uint16[] calldata bps_) external onlyOwner {
        require(thresholds.length == bps_.length && thresholds.length > 0, "bad tiers");
        usdThresholds = thresholds;
        bps = bps_;
        emit FeeTiersSet(thresholds, bps_);
    }

    //计算手续费比例
    function feeBpsFor(uint256 bidUsd) public view returns (uint16) {
        uint16 fee = bps[0];
        for (uint256 i = 0; i < usdThresholds.length; i++) {
            if (bidUsd >= usdThresholds[i]) fee = bps[i];
            else break;
        }
        return fee;
    }

    //创建拍卖
    //nft：NFT 合约地址
    //tokenId：拍卖的 NFT 编号
    //duration：拍卖时长（单位秒）
    //startPriceUsd：起拍价（以 USD 计价，8 位小数）
    function createAuction(
        address nft,
        uint256 tokenId,
        uint64 duration,
        uint256 startPriceUsd
    ) external returns (address auction) {
        require(duration >= 60, "duration too short");
        bytes32 key = keccak256(abi.encode(nft, tokenId));
        require(auctionOf[key] == address(0), "exists");
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + duration;

        bytes memory data = abi.encodeWithSelector(
            IAuction.initialize.selector,
            address(this),
            msg.sender,
            nft,
            tokenId,
            startTime,
            endTime,
            startPriceUsd,
            address(oracle)
        );
        auction = address(new ERC1967Proxy(auctionImplementation, data));
        auctionOf[key] = auction;
        allAuctions.push(auction);

        // 转移 NFT 给拍卖合约
        // 卖家必须先在 NFT 合约里 approve 工厂合约
        IERC721(nft).safeTransferFrom(msg.sender, auction, tokenId);
        emit AuctionCreated(auction, nft, tokenId, msg.sender);
    }

    function allAuctionsLength() external view returns (uint256) {
        return allAuctions.length;
    }
}
