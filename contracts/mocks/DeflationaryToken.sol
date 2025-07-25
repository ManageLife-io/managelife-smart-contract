// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DeflationaryToken
 * @dev A mock ERC20 token that charges a transfer fee (deflationary mechanism)
 * Used for testing deflationary token compatibility
 */
contract DeflationaryToken is ERC20, Ownable {
    uint256 public transferFeeRate; // Fee rate in basis points (e.g., 1000 = 10%)
    uint256 public constant MAX_FEE_RATE = 2000; // Maximum 20% fee
    
    event TransferFeeChanged(uint256 oldRate, uint256 newRate);
    event FeeCollected(address indexed from, address indexed to, uint256 amount, uint256 fee);
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 /* decimals */,
        uint256 _transferFeeRate
    ) ERC20(name, symbol) {
        require(_transferFeeRate <= MAX_FEE_RATE, "Fee rate too high");
        transferFeeRate = _transferFeeRate;
        _transferOwnership(msg.sender);
    }
    
    /**
     * @dev Override transfer to implement deflationary mechanism
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transferWithFee(owner, to, amount);
        return true;
    }
    
    /**
     * @dev Override transferFrom to implement deflationary mechanism
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transferWithFee(from, to, amount);
        return true;
    }
    
    /**
     * @dev Internal transfer function with fee deduction
     */
    function _transferWithFee(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        
        uint256 fromBalance = balanceOf(from);
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        
        // Calculate fee
        uint256 fee = (amount * transferFeeRate) / 10000;
        uint256 transferAmount = amount - fee;
        
        // Perform transfers
        _burn(from, amount); // Remove full amount from sender
        _mint(to, transferAmount); // Give net amount to receiver
        
        // Fee is effectively burned (deflationary)
        
        emit FeeCollected(from, to, amount, fee);
    }
    
    /**
     * @dev Mint tokens (only owner)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    /**
     * @dev Burn tokens (only owner)
     */
    function burn(uint256 amount) external onlyOwner {
        _burn(msg.sender, amount);
    }
    
    /**
     * @dev Set transfer fee rate (only owner)
     */
    function setTransferFeeRate(uint256 _transferFeeRate) external onlyOwner {
        require(_transferFeeRate <= MAX_FEE_RATE, "Fee rate too high");
        uint256 oldRate = transferFeeRate;
        transferFeeRate = _transferFeeRate;
        emit TransferFeeChanged(oldRate, _transferFeeRate);
    }
    
    /**
     * @dev Get effective transfer amount after fee
     */
    function getTransferAmountAfterFee(uint256 amount) external view returns (uint256) {
        uint256 fee = (amount * transferFeeRate) / 10000;
        return amount - fee;
    }
    
    /**
     * @dev Get transfer fee for a given amount
     */
    function getTransferFee(uint256 amount) external view returns (uint256) {
        return (amount * transferFeeRate) / 10000;
    }
}
