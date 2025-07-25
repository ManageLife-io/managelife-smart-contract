const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PropertyMarket", function () {
  let PropertyMarket, NFTi, LifeToken;
  let propertyMarket, nfti, lifeToken;
  let owner, seller, buyer, addr1;
  let adminControl;

  beforeEach(async function () {
    [owner, seller, buyer, addr1] = await ethers.getSigners();
    console.log("Starting deployment with owner:", owner.address);

    try {
      // Deploy AdminControl first
      console.log("Deploying AdminControl...");
      const AdminControl = await ethers.getContractFactory("AdminControl");
      adminControl = await AdminControl.deploy(
        owner.address,
        owner.address,
        owner.address
      );
      await adminControl.deployed();
      console.log("AdminControl deployed successfully at:", adminControl.address);
    } catch (error) {
      console.log("AdminControl deployment failed:", error.message);
      throw error;
    }

    try {
      // Deploy LifeToken
      console.log("Deploying LifeToken...");
      const LifeToken = await ethers.getContractFactory("LifeToken");
      lifeToken = await LifeToken.deploy(owner.address);
      await lifeToken.deployed();
      console.log("LifeToken deployed successfully at:", lifeToken.address);
    } catch (error) {
      console.log("LifeToken deployment failed:", error.message);
      throw error;
    }

    try {
      // Deploy NFTi
      console.log("Deploying NFTi...");
      const NFTi = await ethers.getContractFactory("NFTi");
      nfti = await NFTi.deploy();
      await nfti.deployed();
      console.log("NFTi deployed successfully at:", nfti.address);
      
      // Set NFTm contract address
      await nfti.setNFTmContract(adminControl.address);
      console.log("NFTm contract set to AdminControl");
    } catch (error) {
      console.log("NFTi deployment failed:", error.message);
      throw error;
    }

    try {
      // Deploy PropertyMarket
      console.log("Deploying PropertyMarket...");
      const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
      propertyMarket = await PropertyMarket.deploy(
        nfti.address,
        nfti.address,
        owner.address,
        owner.address,
        owner.address
      );
      await propertyMarket.deployed();
      console.log("PropertyMarket deployed successfully at:", propertyMarket.address);
    } catch (error) {
      console.log("PropertyMarket deployment failed:", error.message);
      throw error;
    }

    console.log("All contracts deployed successfully!");
  });

  describe("Deployment", function () {
    it("Should set the correct NFT contract", async function () {
      expect(await propertyMarket.nftContract()).to.equal(nfti.address);
    });

    it("Should set the correct payment token", async function () {
      expect(await propertyMarket.paymentToken()).to.equal(lifeToken.address);
    });

    it("Should set the correct admin control", async function () {
      expect(await propertyMarket.adminControl()).to.equal(adminControl.address);
    });
  });

  describe("Listing Properties", function () {
    beforeEach(async function () {
      // Approve PropertyMarket to transfer NFT
      await nfti.connect(seller).approve(propertyMarket.address, 1);
    });

    it("Should allow NFT owner to list property", async function () {
      const price = ethers.utils.parseEther("1000");
      
      await expect(
        propertyMarket.connect(seller).listProperty(1, price)
      ).to.emit(propertyMarket, "PropertyListed")
        .withArgs(1, seller.address, price);
      
      const listing = await propertyMarket.getPropertyListing(1);
      expect(listing.seller).to.equal(seller.address);
      expect(listing.price).to.equal(price);
      expect(listing.isActive).to.be.true;
    });

    it("Should not allow non-owner to list property", async function () {
      const price = ethers.utils.parseEther("1000");
      
      await expect(
        propertyMarket.connect(buyer).listProperty(1, price)
      ).to.be.revertedWith("Not the owner of this NFT");
    });

    it("Should not allow listing with zero price", async function () {
      await expect(
        propertyMarket.connect(seller).listProperty(1, 0)
      ).to.be.revertedWith("Price must be greater than 0");
    });

    it("Should not allow listing already listed property", async function () {
      const price = ethers.utils.parseEther("1000");
      
      await propertyMarket.connect(seller).listProperty(1, price);
      
      await expect(
        propertyMarket.connect(seller).listProperty(1, price)
      ).to.be.revertedWith("Property already listed");
    });
  });

  describe("Buying Properties", function () {
    const price = ethers.utils.parseEther("1000");

    beforeEach(async function () {
      // List property
      await nfti.connect(seller).approve(propertyMarket.address, 1);
      await propertyMarket.connect(seller).listProperty(1, price);
      
      // Approve PropertyMarket to spend buyer's tokens
      await lifeToken.connect(buyer).approve(propertyMarket.address, price);
    });

    it("Should allow buyer to purchase listed property", async function () {
      await expect(
        propertyMarket.connect(buyer).buyProperty(1)
      ).to.emit(propertyMarket, "PropertySold")
        .withArgs(1, seller.address, buyer.address, price);
      
      // Check NFT ownership transfer
      expect(await nfti.ownerOf(1)).to.equal(buyer.address);
      
      // Check token transfer
      expect(await lifeToken.balanceOf(seller.address)).to.equal(price);
      
      // Check listing is deactivated
      const listing = await propertyMarket.getPropertyListing(1);
      expect(listing.isActive).to.be.false;
    });

    it("Should not allow buying unlisted property", async function () {
      await expect(
        propertyMarket.connect(buyer).buyProperty(2)
      ).to.be.revertedWith("Property not listed or inactive");
    });

    it("Should not allow seller to buy their own property", async function () {
      await expect(
        propertyMarket.connect(seller).buyProperty(1)
      ).to.be.revertedWith("Seller cannot buy their own property");
    });

    it("Should not allow buying with insufficient funds", async function () {
      // Reset buyer's token balance to insufficient amount
      const buyerBalance = await lifeToken.balanceOf(buyer.address);
      await lifeToken.connect(buyer).transfer(addr1.address, buyerBalance);
      
      await expect(
        propertyMarket.connect(buyer).buyProperty(1)
      ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
    });
  });

  describe("Bidding System", function () {
    const listPrice = ethers.utils.parseEther("1000");
    const bidAmount = ethers.utils.parseEther("800");

    beforeEach(async function () {
      // List property
      await nfti.connect(seller).approve(propertyMarket.address, 1);
      await propertyMarket.connect(seller).listProperty(1, listPrice);
      
      // Approve tokens for bidding
      await lifeToken.connect(buyer).approve(propertyMarket.address, bidAmount);
      await lifeToken.connect(addr1).approve(propertyMarket.address, bidAmount);
    });

    it("Should allow placing bid on listed property", async function () {
      await expect(
        propertyMarket.connect(buyer).placeBid(1, bidAmount)
      ).to.emit(propertyMarket, "BidPlaced")
        .withArgs(1, buyer.address, bidAmount);
      
      const bid = await propertyMarket.getBid(1, buyer.address);
      expect(bid.amount).to.equal(bidAmount);
      expect(bid.bidder).to.equal(buyer.address);
    });

    it("Should not allow bidding on unlisted property", async function () {
      await expect(
        propertyMarket.connect(buyer).placeBid(2, bidAmount)
      ).to.be.revertedWith("Property not listed or inactive");
    });

    it("Should not allow seller to bid on their own property", async function () {
      await expect(
        propertyMarket.connect(seller).placeBid(1, bidAmount)
      ).to.be.revertedWith("Seller cannot bid on their own property");
    });

    it("Should allow updating bid amount", async function () {
      await propertyMarket.connect(buyer).placeBid(1, bidAmount);
      
      const newBidAmount = ethers.utils.parseEther("900");
      await lifeToken.connect(buyer).approve(propertyMarket.address, newBidAmount);
      
      await expect(
        propertyMarket.connect(buyer).placeBid(1, newBidAmount)
      ).to.emit(propertyMarket, "BidPlaced")
        .withArgs(1, buyer.address, newBidAmount);
      
      const bid = await propertyMarket.getBid(1, buyer.address);
      expect(bid.amount).to.equal(newBidAmount);
    });

    it("Should allow seller to accept bid", async function () {
      await propertyMarket.connect(buyer).placeBid(1, bidAmount);
      
      await expect(
        propertyMarket.connect(seller).acceptBid(1, buyer.address)
      ).to.emit(propertyMarket, "BidAccepted")
        .withArgs(1, buyer.address, bidAmount);
      
      // Check NFT ownership transfer
      expect(await nfti.ownerOf(1)).to.equal(buyer.address);
      
      // Check token transfer
      expect(await lifeToken.balanceOf(seller.address)).to.equal(bidAmount);
    });

    it("Should allow withdrawing bid", async function () {
      await propertyMarket.connect(buyer).placeBid(1, bidAmount);
      
      const initialBalance = await lifeToken.balanceOf(buyer.address);
      
      await expect(
        propertyMarket.connect(buyer).withdrawBid(1)
      ).to.emit(propertyMarket, "BidWithdrawn")
        .withArgs(1, buyer.address, bidAmount);
      
      // Check tokens are returned
      expect(await lifeToken.balanceOf(buyer.address)).to.equal(
        initialBalance.add(bidAmount)
      );
      
      // Check bid is removed
      const bid = await propertyMarket.getBid(1, buyer.address);
      expect(bid.amount).to.equal(0);
    });
  });

  describe("Delisting Properties", function () {
    const price = ethers.utils.parseEther("1000");

    beforeEach(async function () {
      await nfti.connect(seller).approve(propertyMarket.address, 1);
      await propertyMarket.connect(seller).listProperty(1, price);
    });

    it("Should allow seller to delist property", async function () {
      await expect(
        propertyMarket.connect(seller).delistProperty(1)
      ).to.emit(propertyMarket, "PropertyDelisted")
        .withArgs(1, seller.address);
      
      const listing = await propertyMarket.getPropertyListing(1);
      expect(listing.isActive).to.be.false;
    });

    it("Should not allow non-seller to delist property", async function () {
      await expect(
        propertyMarket.connect(buyer).delistProperty(1)
      ).to.be.revertedWith("Only seller can delist");
    });

    it("Should not allow delisting unlisted property", async function () {
      await expect(
        propertyMarket.connect(seller).delistProperty(2)
      ).to.be.revertedWith("Property not listed or already inactive");
    });
  });

  describe("View Functions", function () {
    const price = ethers.utils.parseEther("1000");

    beforeEach(async function () {
      await nfti.connect(seller).approve(propertyMarket.address, 1);
      await propertyMarket.connect(seller).listProperty(1, price);
    });

    it("Should return correct property listing", async function () {
      const listing = await propertyMarket.getPropertyListing(1);
      expect(listing.seller).to.equal(seller.address);
      expect(listing.price).to.equal(price);
      expect(listing.isActive).to.be.true;
    });

    it("Should return all active listings", async function () {
      // List another property
      await nfti.connect(seller).approve(propertyMarket.address, 2);
      await propertyMarket.connect(seller).listProperty(2, price);
      
      const activeListings = await propertyMarket.getActiveListings();
      expect(activeListings.length).to.equal(2);
    });

    it("Should return bids for property", async function () {
      const bidAmount = ethers.utils.parseEther("800");
      await lifeToken.connect(buyer).approve(propertyMarket.address, bidAmount);
      await propertyMarket.connect(buyer).placeBid(1, bidAmount);
      
      const bids = await propertyMarket.getPropertyBids(1);
      expect(bids.length).to.equal(1);
      expect(bids[0].bidder).to.equal(buyer.address);
      expect(bids[0].amount).to.equal(bidAmount);
    });
  });
});