const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PropertyMarket - Bid Cleanup Functionality", function () {
  let PropertyMarket, NFTi, LifeToken, AdminControl;
  let propertyMarket, nfti, lifeToken, adminControl;
  let owner, seller, buyer1, buyer2, buyer3;
  let tokenId;

  beforeEach(async function () {
    [owner, seller, buyer1, buyer2, buyer3] = await ethers.getSigners();

    // Deploy AdminControl
    AdminControl = await ethers.getContractFactory("AdminControl");
    adminControl = await AdminControl.deploy(
      owner.address,
      owner.address,
      owner.address
    );
    await adminControl.deployed();

    // Deploy LifeToken
    LifeToken = await ethers.getContractFactory("LifeToken");
    lifeToken = await LifeToken.deploy(owner.address);
    await lifeToken.deployed();

    // Deploy NFTi
    NFTi = await ethers.getContractFactory("NFTi");
    nfti = await NFTi.deploy();
    await nfti.deployed();
    await nfti.setNFTmContract(adminControl.address);

    // Deploy PropertyMarket
    PropertyMarket = await ethers.getContractFactory("PropertyMarket");
    propertyMarket = await PropertyMarket.deploy(
      nfti.address,
      nfti.address,
      owner.address,
      owner.address,
      owner.address
    );
    await propertyMarket.deployed();

    // We'll mint NFT in the nested beforeEach to ensure unique token IDs
    
    // Add KYC verification for all users in PropertyMarket (since it inherits from AdminControl)
    console.log("Adding KYC verification...");
    await propertyMarket.connect(owner).batchApproveKYC([seller.address, buyer1.address, buyer2.address, buyer3.address], true);
    console.log("KYC verification added");

    // We'll use ETH for testing since it's already allowed by default
    // No need to transfer tokens or add payment methods
  });

  describe("Bid Cleanup Functionality", function () {
    const listPrice = ethers.utils.parseEther("1");
    const bidAmount1 = ethers.utils.parseEther("1.1");
    const bidAmount2 = ethers.utils.parseEther("1.2");
    const bidAmount3 = ethers.utils.parseEther("1.3");

    beforeEach(async function () {
      // Mint NFT to seller - NFTi auto-generates token ID
      const legalId = `legal-${Math.floor(Math.random() * 1000000)}`;
      const tx = await nfti.connect(owner).mint(seller.address, legalId, false);
      const receipt = await tx.wait();

      // Get the token ID from the Transfer event
      const transferEvent = receipt.events?.find(e => e.event === 'Transfer');
      tokenId = transferEvent?.args?.tokenId?.toNumber() || 1;

      // List property with ETH as payment method
      await nfti.connect(seller).approve(propertyMarket.address, tokenId);
      await propertyMarket.connect(seller).listProperty(tokenId, listPrice, ethers.constants.AddressZero);

      // No need to approve tokens since we're using ETH
    });

    it("Should clean up inactive bids when called manually", async function () {
      // Place multiple bids with ETH
      await propertyMarket.connect(buyer1).placeBid(tokenId, bidAmount1, ethers.constants.AddressZero, { value: bidAmount1 });
      await propertyMarket.connect(buyer2).placeBid(tokenId, bidAmount2, ethers.constants.AddressZero, { value: bidAmount2 });
      await propertyMarket.connect(buyer3).placeBid(tokenId, bidAmount3, ethers.constants.AddressZero, { value: bidAmount3 });

      // Verify all bids are active
      let activeBids = await propertyMarket.getActiveBidsForToken(tokenId);
      expect(activeBids.length).to.equal(3);

      // Cancel one bid
      await propertyMarket.connect(buyer1).cancelBid(tokenId);

      // Verify we have 2 active bids but still 3 total bids in array
      activeBids = await propertyMarket.getActiveBidsForToken(tokenId);
      expect(activeBids.length).to.equal(2);

      // Call cleanup function
      await expect(propertyMarket.cleanupInactiveBids(tokenId))
        .to.emit(propertyMarket, "BidsCleanedUp")
        .withArgs(tokenId, 1, 2); // 1 removed, 2 remaining

      // Verify cleanup worked
      activeBids = await propertyMarket.getActiveBidsForToken(tokenId);
      expect(activeBids.length).to.equal(2);
      
      // Verify the remaining bids are the correct ones
      expect(activeBids[0].bidder).to.equal(buyer2.address);
      expect(activeBids[1].bidder).to.equal(buyer3.address);
    });

    it("Should not clean up if all bids are active", async function () {
      // Place multiple bids with ETH
      await propertyMarket.connect(buyer1).placeBid(tokenId, bidAmount1, ethers.constants.AddressZero, { value: bidAmount1 });
      await propertyMarket.connect(buyer2).placeBid(tokenId, bidAmount2, ethers.constants.AddressZero, { value: bidAmount2 });

      // Call cleanup - should not emit event since no cleanup needed
      const tx = await propertyMarket.cleanupInactiveBids(tokenId);
      const receipt = await tx.wait();
      
      // Check that no BidsCleanedUp event was emitted
      const cleanupEvents = receipt.events?.filter(e => e.event === "BidsCleanedUp");
      expect(cleanupEvents?.length || 0).to.equal(0);
    });

    it("Should handle empty bid array gracefully", async function () {
      // Call cleanup on token with no bids
      const tx = await propertyMarket.cleanupInactiveBids(tokenId);
      const receipt = await tx.wait();
      
      // Should not emit any events
      const cleanupEvents = receipt.events?.filter(e => e.event === "BidsCleanedUp");
      expect(cleanupEvents?.length || 0).to.equal(0);
    });

    it("Should update bidder indices correctly after cleanup", async function () {
      // Place bids with ETH
      await propertyMarket.connect(buyer1).placeBid(tokenId, bidAmount1, ethers.constants.AddressZero, { value: bidAmount1 });
      await propertyMarket.connect(buyer2).placeBid(tokenId, bidAmount2, ethers.constants.AddressZero, { value: bidAmount2 });
      await propertyMarket.connect(buyer3).placeBid(tokenId, bidAmount3, ethers.constants.AddressZero, { value: bidAmount3 });

      // Cancel middle bid
      await propertyMarket.connect(buyer2).cancelBid(tokenId);

      // Clean up
      await propertyMarket.cleanupInactiveBids(tokenId);

      // Check that bidder indices are updated correctly
      const bid1 = await propertyMarket.getBidFromBidder(tokenId, buyer1.address);
      const bid2 = await propertyMarket.getBidFromBidder(tokenId, buyer2.address);
      const bid3 = await propertyMarket.getBidFromBidder(tokenId, buyer3.address);

      expect(bid1.isActive).to.be.true;
      expect(bid2.isActive).to.be.false; // Should return default empty bid
      expect(bid3.isActive).to.be.true;
    });
  });
});
