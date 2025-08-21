// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MyNFT is ERC721, Ownable {
    uint256 private _nextId = 1;
    string private _base;

    constructor(string memory name_, string memory symbol_, string memory baseURI_) ERC721(name_, symbol_) Ownable(msg.sender) {
        _base = baseURI_;
    }

    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextId++;
        _mint(to, tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _base;
    }

    function setBaseURI(string calldata newBase) external onlyOwner {
        _base = newBase;
    }
}
