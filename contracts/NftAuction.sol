// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PriceOracle} from "./PriceOracle.sol";

interface IFactoryView {
    function owner() external view returns (address);
    function feeTo() external view returns (address);
    function feeBpsFor(uint256) external view returns (uint16);
}

contract NftAuction is Initializable, ReentrancyGuardUpgradeable, UUPSUpgradeable, OwnableUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    event BidPlaced(address indexed bidder, address indexed token, uint256 amount, uint256 usdValue);
    event AuctionEnded(address winner, address token, uint256 amount, uint256 usdValue, uint16 feeBps);
    event Cancelled();

    IERC721 public nft;
    uint256 public tokenId;
    address public seller;
    uint64 public startTime;
    uint64 public endTime;
    uint256 public startPriceUsd; // 8 decimals
    PriceOracle public oracle;
    address public factory;
    //定义出价结构体
    struct Bid {
        address bidder;
        address token; // address(0) for ETH
        uint256 amount; // token units or wei
        uint256 usdValue; // 8 decimals
    }
    //最高出价者
    Bid public highest;

    //最小加价usd
    uint256 public minIncrementUsd; // optional 8 decimals

    function initialize(
        address factory_,
        address seller_,
        address nft_,
        uint256 tokenId_,
        uint64 startTime_,
        uint64 endTime_,
        uint256 startPriceUsd_,
        address oracle_
    ) external initializer {

        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender); // 作为所有者的部署者（工厂）；卖方单独存放
        factory = factory_;
        seller = seller_;
        nft = IERC721(nft_);
        tokenId = tokenId_;
        startTime = startTime_;
        endTime = endTime_;
        startPriceUsd = startPriceUsd_;
        oracle = PriceOracle(oracle_);
        minIncrementUsd = 1_0000_0000; // default $1
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == IFactoryView(factory).owner(), "not authorized");
    }

    modifier onlyActive() {
        require(block.timestamp >= startTime && block.timestamp < endTime, "not active");
        _;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function timeLeft() external view returns (uint256) {
        if (block.timestamp >= endTime) return 0;
        return endTime - block.timestamp;
    }

    function currentFeeBps() public view returns (uint16) {
        return IFactoryView(factory).feeBpsFor(highest.usdValue);
    }

    /// @notice ETH出价
    function bidETH() external payable onlyActive nonReentrant {
        require(msg.value > 0, "no value");
        uint256 usd = oracle.toUSD(address(0), msg.value);
        _placeBid(msg.sender, address(0), msg.value, usd);
    }

    /// @notice ERC20出价
    function bidERC20(address token, uint256 amount) external onlyActive nonReentrant {
        require(amount > 0, "no amount");
        uint256 usd = oracle.toUSD(token, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _placeBid(msg.sender, token, amount, usd);
    }

    function _placeBid(address bidder, address token, uint256 amount, uint256 usd) internal {
        require(usd >= startPriceUsd, "below start price");
        //当前没有人出价
        if (highest.bidder == address(0)) {
            // ok
        } else {
            require(usd >= highest.usdValue + minIncrementUsd, "too low");
        }
        // 有人出价
        if (highest.bidder != address(0)) {
            if (highest.token == address(0)) {
                (bool ok,) = highest.bidder.call{value: highest.amount}("");
                require(ok, "refund eth failed");
            } else {
                IERC20(highest.token).safeTransfer(highest.bidder, highest.amount);
            }
        }
        highest = Bid({bidder: bidder, token: token, amount: amount, usdValue: usd});
        emit BidPlaced(bidder, token, amount, usd);
    }

    function endAuction() external nonReentrant {
        require(block.timestamp >= endTime, "not ended");
        address _feeTo = IFactoryView(factory).feeTo();
        if (highest.bidder == address(0)) {
            // 没有出价
            nft.safeTransferFrom(address(this), seller, tokenId);
            emit Cancelled();
            return;
        }
        // 给出价者转移 NFT
        nft.safeTransferFrom(address(this), highest.bidder, tokenId);

        // 支付，计算手续费费率
        uint16 feeBps = IFactoryView(factory).feeBpsFor(highest.usdValue);
        uint256 fee = highest.amount * feeBps / 10_000;
        uint256 sellerAmt = highest.amount - fee;//卖方拍卖价

        if (highest.token == address(0)) {
            (bool ok1,) = _feeTo.call{value: fee}("");
            require(ok1, "fee eth failed");
            (bool ok2,) = seller.call{value: sellerAmt}("");
            require(ok2, "payout eth failed");
        } else {
            IERC20(highest.token).safeTransfer(_feeTo, fee);
            IERC20(highest.token).safeTransfer(seller, sellerAmt);
        }

        emit AuctionEnded(highest.bidder, highest.token, highest.amount, highest.usdValue, feeBps);
    }

    // 工厂所有者可以设置加价最小usd
    function setMinIncrementUsd(uint256 newMin) external {
        require(msg.sender == IFactoryView(factory).owner() || msg.sender == seller, "no auth");
        minIncrementUsd = newMin;
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        // 仅合约 owner可提走误转到本合约的资产（包括 ETH）；不限制时机，因此需信任工厂方。
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "withdraw eth failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
