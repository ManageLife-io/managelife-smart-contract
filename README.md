# Manage Life Smart Contracts

## Contracts 

### ProperyMarket.sol
This contract is the core contract that deals with the listing of iNFTs (the properties), creating bids on properties, and managing payments for properties.

Possible Refactor Notes:
- The usage of a multisig contract for controlling the timelock seems to me to be overengineering. Its debatable if a timelock is necesary to add new payment tokens and update listings. Also, using a multisig contract in the repo instead of using the latest from GNOSIS is potentially dangerous.
- Adding the ability to use a deflationary token seems to be managed correctly, but the question is, why would we want that? Most stablecoins like USDC and USDT are not deflationary, and I'm guessing that big payments would likely be done in such stablecoins. The LifeToken is a rebasing token, so I'm guessing that it's for that.
- This contract likely needs some cleanup, there's too many nested internal functions that are not re-used.  

### AdminControl.sol
This contract contains core configurable settings for the whole protocol, including:
- Pausing of the whole protocol.
- Pausing of specific features.
- Fee parameters
- Reward parameters
- Setting of KYC status
- Setting of community scores
- Role management: OPERATOR, LEGAL, REWARD MANAGER

Possible Refactor Notes:
- KYC functionality could be refactored into its own contract.
- This contract should be only for reading core protocol params, and not doing calculations on them, so functions like `calculateRewards()` give some code smells.
- It seems that the pause functionaly here is not applied/read anywhere.

### LifeToken.sol
- ERC20 token intended to be the protocol's core token, perhaps also to be used for payment in bids/nft transfers.
- It is a rebasing token similar to Ampleforth, but the reason for this is not exactly clear.
- The token has no erc20Votes/governance power.
- The token has some timelock properties to it, like ownership transfer. The question is why? And why not use a timelock contract for it?

Possible Refactor Notes:
- Rebasing can lock out the token from the greater defi ecosystem, this is a model that is not used very often and its most useful case is for rebasing Stablecoins, which I don't think this is.
- Need to rethink the timelock properties, it might be over-engineering.


### NFTm.sol
- This NFT represents the legal title of a property.
- Each NFTm is linked 1:1 with an NFTi.
- Each NFTm contains information about the LLC that holds the property.

### NFTi.sol
- NFT that represents a property for trade on the platform, represents the physical asset.

Possible Refactor Notes:
- Having 2 NFT contracts for what essentially is the same property, if indeed the realtionship is supposed to be 1:1, is very hard to manage. If they are not supposed to freely transfer independently, it can be a single NFT contract. If they can freely transfer, they need to be tied together in a better way, like using an ERC1155 contract instead.


### BaseRewards.sol
This contract is a pretty standard staking contract that allows users to stake a token to earn rewards of another token via the standard "reward per token" mechanism. The only difference is that it includes bonus rewards called "community bonus".

Possible Refactor Notes:
- References to "safemath" makes me think that this was written before 2021, it needs to be checked that there's no outdated things from that era. 
- Logic around bonuses needs to be checked, as they are deeply intertwined right now.
- We need to think why we're requiring staking, because we're not giving governance power, nor giving back a receipt token that can be used in defi.

### DynamicRewards.sol
This is another rewards contract that is for time-boxed, scheduled, rewards. 

Possible Refactor Notes:
- Why are there 2 rewards contracts? What are the tokenomics like for the reward token so that it requires both continious streaming of rewards but also scheduled rewards?

