// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC20
/// @notice Mock ERC20 contract for testing purposes
contract MockERC20 is ERC20, Ownable {
    uint8 private _decimals;
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    /// @notice Mint tokens to a specific address
    /// @param to Address to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    /// @notice Burn tokens from a specific address
    /// @param from Address to burn tokens from
    /// @param amount Amount of tokens to burn
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
    
    /// @notice Override decimals function
    /// @return Number of decimals
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    /// @notice Mint tokens to caller (for testing convenience)
    /// @param amount Amount of tokens to mint
    function mintToSelf(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
