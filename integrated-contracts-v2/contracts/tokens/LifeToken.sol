// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title LifeToken - A Fully Decentralized ERC20 Token With Governance Capabilities
 * @author Jose Herrera
 * @notice A protocol token designed for maximum decentralization and DeFi composability with governance capabilities.
 * @dev This contract implements ERC20 with voting capabilities and gasless approvals
 * 
 * Key Features:
 * - Fixed supply: The entire maximum supply is minted at deployment with no possibility of further minting
 * - Voting capabilities: Supports delegation and vote tracking for decentralized governance
 * - Gasless approvals: EIP-2612 permit functionality allows users to approve spending without gas
 * - Fully decentralized: No owner, admin roles, or pausability mechanisms
 * - DeFi compatible: Designed to integrate seamlessly with DEXs, lending protocols, and other DeFi applications
 * 
 * Security Model:
 * - Immutable tokenomics: Total supply is permanently fixed at deployment
 * - No admin controls: Cannot be paused, frozen, or administratively controlled
 * - Unstoppable transfers: Follows the same security model as major DeFi tokens (UNI, AAVE, COMP)
 */
contract LifeToken is ERC20, ERC20Permit, ERC20Votes {
    
    // =============================
    // Constants
    // =============================
    
    /// @notice Maximum and total token supply (5 billion tokens with 18 decimals)
    /// @dev This supply is minted once at deployment and cannot be increased
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 1e18;

    // =============================
    // Constructor
    // =============================
    
    /**
     * @notice Initializes the LifeToken contract with fixed supply and governance capabilities
     * @dev Mints the entire maximum supply to the specified destination address
     * @param initialMintDestination_ The address that will receive the entire token supply
     * @param name_ The human-readable name of the token (e.g., "LifeToken")
     * @param symbol_ The token symbol (e.g., "LIFE")
     * 
     * Requirements:
     * - initialMintDestination_ cannot be the zero address (handled by _mint)
     * 
     * Effects:
     * - Sets up ERC20 basic functionality with name and symbol
     * - Initializes EIP-712 domain for permit functionality
     * - Mints entire MAX_SUPPLY to initialMintDestination_
     * - No admin roles or ownership is established
     */
    constructor(address initialMintDestination_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(initialMintDestination_, MAX_SUPPLY);
    }

    // =============================
    // Internal Overrides
    // =============================

    /**
     * @notice Internal function called after token transfers, mints, and burns
     * @dev Overrides both ERC20 and ERC20Votes to enable vote tracking on balance changes
     * @param from The address tokens are transferred from (address(0) for minting)
     * @param to The address tokens are transferred to (address(0) for burning)
     * @param amount The amount of tokens being transferred
     *
     * Note: This function automatically updates voting power when tokens are transferred,
     * enabling accurate governance participation tracking.
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    /**
     * @notice Internal function for minting tokens
     * @dev Overrides both ERC20 and ERC20Votes to enable vote tracking on minting
     */
    function _mint(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(account, amount);
    }

    /**
     * @notice Internal function for burning tokens
     * @dev Overrides both ERC20 and ERC20Votes to enable vote tracking on burning
     */
    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }

    /**
     * @notice Returns the current nonce for permit and delegation signatures
     * @dev Inherited from ERC20Permit and ERC20Votes
     * @param owner The address to query the nonce for
     * @return The current nonce value for the specified address
     *
     * Note: This nonce is used for both EIP-2612 permit approvals and vote delegation signatures,
     * providing replay protection for gasless transactions.
     */
    function nonces(address owner) public view override(ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}