// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./../governance/AdminControl.sol";

interface INFTm {
    function handleNFTiBurn(uint256 nftiTokenId) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract NFTi is ERC721, Ownable, ReentrancyGuard {
    uint256 public tokenCounter;
    address public marketContract;
    address public nftmContract;

    struct Property {
        string legalId;
        bool isManaged;
        uint256 createdAt;
    }

    mapping(uint256 => Property) public properties;

    constructor() ERC721("ManageLife NFTi", "NFTi") Ownable() {
        tokenCounter = 1;
    }
    
    function setNFTmContract(address _nftmContract) external onlyOwner {
        require(_nftmContract != address(0), "Invalid NFTm contract address");
        nftmContract = _nftmContract;
    }

    function mint(address to, string memory legalId, bool managed) external nonReentrant returns (uint256) {
        require(INFTm(nftmContract).hasRole(keccak256("OPERATOR_ROLE"), msg.sender), "NFTi: caller lacks operator role");
        
        uint256 newTokenId = tokenCounter++;
        properties[newTokenId] = Property(legalId, managed, block.timestamp);
        
        _safeMint(to, newTokenId);
        
        return newTokenId;
    }

    function burn(uint256 tokenId) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        
        _burn(tokenId);
        delete properties[tokenId];
        
        if (nftmContract != address(0)) {
            try INFTm(nftmContract).handleNFTiBurn(tokenId) {
            } catch {
            }
        }
    }
}