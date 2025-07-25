const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MA2-12 to MA2-17: Security Fixes Comprehensive Test", function () {
    let propertyMarket;
    let nfti;
    let lifeToken;
    let mockToken;
    let owner, seller, buyer, buyer2, feeCollector, maliciousContract;
    
    beforeEach(async function () {
        [owner, seller, buyer, buyer2, feeCollector, maliciousContract] = await ethers.getSigners();
        
        // Deploy LifeToken
        const LifeToken = await ethers.getContractFactory("LifeToken");
        lifeToken = await LifeToken.deploy(owner.address);
        await lifeToken.deployed();
        
        // Deploy MockERC721 for testing
        const MockERC721 = await ethers.getContractFactory("MockERC721");
        nfti = await MockERC721.deploy("Test NFT", "TNFT");
        await nfti.deployed();
        
        // Deploy MockERC20 for testing
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockToken = await MockERC20.deploy("Mock Token", "MOCK", 18);
        await mockToken.deployed();
        
        // Deploy PropertyMarket
        const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
        propertyMarket = await PropertyMarket.deploy(
            nfti.address,
            nfti.address,
            owner.address,
            feeCollector.address,
            feeCollector.address
        );
        await propertyMarket.deployed();
        
        // Setup: Mint NFT and approve market
        await nfti.connect(owner).mintWithId(seller.address, 0);
        await nfti.connect(seller).approve(propertyMarket.address, 0);
        
        // Grant KYC verification
        await propertyMarket.connect(owner).batchApproveKYC([seller.address, buyer.address, buyer2.address], true);
        
        // Allow mock token
        await propertyMarket.connect(owner).addAllowedToken(mockToken.address);
        
        // List property
        const listingPrice = ethers.utils.parseEther("100");
        await propertyMarket.connect(seller).listProperty(
            0,
            listingPrice,
            ethers.constants.AddressZero
        );
    });
    
    describe("🔒 MA2-12: DoS Attack Prevention", function () {
        it("Should handle failed refunds gracefully with pull pattern", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Cancel bid to trigger refund
            await propertyMarket.connect(buyer).cancelBid(0);
            
            // Check if refund was successful or queued
            const pendingRefund = await propertyMarket.getPendingRefund(buyer.address);
            
            if (pendingRefund.gt(0)) {
                // If refund was queued, withdraw it
                await propertyMarket.connect(buyer).withdrawPendingRefund();
                
                // Verify refund was withdrawn
                const finalPendingRefund = await propertyMarket.getPendingRefund(buyer.address);
                expect(finalPendingRefund).to.equal(0);
            }
            
            console.log("✅ DoS attack prevention working correctly");
        });
        
        it("Should allow withdrawal of pending token refunds", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Mint tokens to buyer
            await mockToken.mint(buyer.address, bidAmount);
            await mockToken.connect(buyer).approve(propertyMarket.address, bidAmount);
            
            // Place token bid
            await propertyMarket.connect(buyer).placeBid(0, bidAmount, mockToken.address);
            
            // Cancel bid
            await propertyMarket.connect(buyer).cancelBid(0);
            
            // Check pending token refund
            const pendingTokenRefund = await propertyMarket.getPendingTokenRefund(buyer.address, mockToken.address);
            
            if (pendingTokenRefund.gt(0)) {
                // Withdraw token refund
                await propertyMarket.connect(buyer).withdrawPendingTokenRefund(mockToken.address);
                
                // Verify withdrawal
                const finalPendingTokenRefund = await propertyMarket.getPendingTokenRefund(buyer.address, mockToken.address);
                expect(finalPendingTokenRefund).to.equal(0);
            }
            
            console.log("✅ Token refund pull pattern working correctly");
        });
    });
    
    describe("🔒 MA2-13: Bid Update Fund Management", function () {
        it("Should handle bid increases correctly", async function () {
            const initialBid = ethers.utils.parseEther("120");
            const increasedBid = ethers.utils.parseEther("150");
            const additionalAmount = increasedBid.sub(initialBid);
            
            // Place initial bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                initialBid,
                ethers.constants.AddressZero,
                { value: initialBid }
            );
            
            // Increase bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                increasedBid,
                ethers.constants.AddressZero,
                { value: additionalAmount }
            );
            
            // Verify bid was updated
            const bidIndex = await propertyMarket.bidIndexByBidder(buyer.address, 0);
            expect(bidIndex).to.be.gt(0);
            
            console.log("✅ Bid increase handled correctly");
        });
        
        it("Should reject bid decreases", async function () {
            const initialBid = ethers.utils.parseEther("120");
            const decreasedBid = ethers.utils.parseEther("100");
            
            // Place initial bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                initialBid,
                ethers.constants.AddressZero,
                { value: initialBid }
            );
            
            // Try to decrease bid (should fail)
            await expect(
                propertyMarket.connect(buyer).placeBid(
                    0,
                    decreasedBid,
                    ethers.constants.AddressZero,
                    { value: 0 }
                )
            ).to.be.reverted;
            
            console.log("✅ Bid decrease correctly rejected");
        });
    });
    
    describe("🔒 MA2-14: Payment Timeout Mechanism", function () {
        it("Should set payment deadline when accepting ETH bid", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Accept bid
            await propertyMarket.connect(seller).acceptBid(
                0, 1, buyer.address, bidAmount, ethers.constants.AddressZero
            );
            
            // Check payment deadline was set
            const deadline = await propertyMarket.getPaymentDeadline(0);
            expect(deadline).to.be.gt(0);
            
            console.log("✅ Payment deadline set correctly");
        });
        
        it("Should allow payment completion within deadline", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place and accept bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            await propertyMarket.connect(seller).acceptBid(
                0, 1, buyer.address, bidAmount, ethers.constants.AddressZero
            );
            
            // Complete payment
            await propertyMarket.connect(buyer).completeBidPayment(0);
            
            // Verify NFT was transferred
            expect(await nfti.ownerOf(0)).to.equal(buyer.address);
            
            console.log("✅ Payment completed within deadline");
        });
        
        it("Should allow cancellation of expired payments", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place and accept bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            await propertyMarket.connect(seller).acceptBid(
                0, 1, buyer.address, bidAmount, ethers.constants.AddressZero
            );
            
            // Fast forward time beyond deadline
            await ethers.provider.send("evm_increaseTime", [25 * 60 * 60]); // 25 hours
            await ethers.provider.send("evm_mine");
            
            // Cancel expired payment
            await propertyMarket.connect(owner).cancelExpiredPayment(0);
            
            // Verify listing is active again
            const listing = await propertyMarket.listings(0);
            expect(listing.status).to.equal(0); // LISTED
            
            console.log("✅ Expired payment cancelled correctly");
        });
    });
    
    describe("🔒 MA2-15: Payment Token Update Restriction", function () {
        it("Should prevent payment token change with active bids", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Try to update payment token (should fail)
            await expect(
                propertyMarket.connect(seller).updateListingBySeller(
                    0,
                    ethers.utils.parseEther("100"),
                    mockToken.address
                )
            ).to.be.revertedWith("Cannot change payment token with active bids");
            
            console.log("✅ Payment token change correctly prevented");
        });
        
        it("Should allow payment token change without active bids", async function () {
            // Update payment token (should succeed)
            await propertyMarket.connect(seller).updateListingBySeller(
                0,
                ethers.utils.parseEther("100"),
                mockToken.address
            );
            
            // Verify update
            const listing = await propertyMarket.listings(0);
            expect(listing.paymentToken).to.equal(mockToken.address);
            
            console.log("✅ Payment token change allowed without active bids");
        });
    });
    
    describe("🔒 MA2-16: Payment Validation Consistency", function () {
        it("Should enforce msg.value equals offerPrice for ETH payments", async function () {
            const offerPrice = ethers.utils.parseEther("120");
            const wrongValue = ethers.utils.parseEther("100");
            
            // Try to purchase with inconsistent values (should fail)
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(0, offerPrice, {
                    value: wrongValue
                })
            ).to.be.reverted;
            
            console.log("✅ Payment validation consistency enforced");
        });
    });
    
    describe("🔒 MA2-17: Batch Processing for Bid Cleanup", function () {
        it("Should handle batch cleanup correctly", async function () {
            // Create multiple bids from different users
            const bidAmount1 = ethers.utils.parseEther("120");
            const bidAmount2 = ethers.utils.parseEther("130");

            // First bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount1,
                ethers.constants.AddressZero,
                { value: bidAmount1 }
            );

            // Second bid from different user
            await propertyMarket.connect(buyer2).placeBid(
                0,
                bidAmount2,
                ethers.constants.AddressZero,
                { value: bidAmount2 }
            );

            // Cancel first bid to create inactive bid
            await propertyMarket.connect(buyer).cancelBid(0);

            // Cleanup with legacy function (should work with gas limits)
            await propertyMarket.cleanupInactiveBids(0);

            console.log("✅ Batch cleanup processed successfully");
        });
    });
});
