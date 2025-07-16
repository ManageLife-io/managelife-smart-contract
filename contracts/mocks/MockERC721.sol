// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC721
/// @notice Mock ERC721 contract for testing purposes
contract MockERC721 is ERC721, Ownable {
    uint256 private _tokenIdCounter;
    
    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}
    
    /// @notice Mint a new token to the specified address
    /// @param to Address to mint the token to
    /// @return tokenId The ID of the minted token
    function mint(address to) external onlyOwner returns (uint256) {
        uint256 tokenId = _tokenIdCounter++;
        _mint(to, tokenId);
        return tokenId;
    }
    
    /// @notice Mint a token with a specific ID
    /// @param to Address to mint the token to
    /// @param tokenId The specific token ID to mint
    function mintWithId(address to, uint256 tokenId) external onlyOwner {
        _mint(to, tokenId);
    }
    
    /// @notice Burn a token
    /// @param tokenId The token ID to burn
    function burn(uint256 tokenId) external {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Not approved or owner");
        _burn(tokenId);
    }
    
    /// @notice Get the current token counter
    /// @return The next token ID that will be minted
    function getCurrentTokenId() external view returns (uint256) {
        return _tokenIdCounter;
    }
    
    /// @notice Check if a token exists
    /// @param tokenId The token ID to check
    /// @return True if the token exists
    function exists(uint256 tokenId) external view returns (bool) {
        return _exists(tokenId);
    }
}
