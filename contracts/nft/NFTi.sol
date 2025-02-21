// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract NFTi is ERC721 {
    uint256 public tokenCounter;
    address public marketContract;

    struct Property {
        string legalId;
        bool isManaged;
        uint256 createdAt;
    }

    mapping(uint256 => Property) public properties;

    constructor() ERC721("ManageLife NFTi", "NFTi") {
        tokenCounter = 1;
    }

    function mint(address to, string memory legalId, bool managed) external returns (uint256) {
        uint256 newTokenId = tokenCounter++;
        _safeMint(to, newTokenId);
        properties[newTokenId] = Property(legalId, managed, block.timestamp);
        return newTokenId;
    }

    function burn(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        _burn(tokenId);
        delete properties[tokenId];
    }
}