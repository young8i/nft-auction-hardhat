// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NftAuction} from "./NftAuction.sol";

contract NftAuctionV2 is NftAuction {
    function version() external pure returns (string memory) {
        return "NftAuctionV2";
    }
}
