const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MA2-04: Listing Cannot Be Updated After NFT Ownership Transfer Fix", function () {
    let propertyMarket;
    let nfti;
    let owner, originalSeller, newOwner, buyer, feeCollector;
    
    beforeEach(async function () {
        [owner, originalSeller, newOwner, buyer, feeCollector] = await ethers.getSigners();
        
        // Deploy MockERC721 for testing
        const MockERC721 = await ethers.getContractFactory("MockERC721");
        nfti = await MockERC721.deploy("Test NFT", "TNFT");
        await nfti.deployed();
        
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
        
        // Setup: Mint NFT to original seller
        await nfti.connect(owner).mintWithId(originalSeller.address, 0);
        
        // Grant KYC verification
        await propertyMarket.connect(owner).batchApproveKYC([originalSeller.address, newOwner.address, buyer.address], true);
    });
    
    describe("🔧 NFT Ownership Transfer Scenarios", function () {
        it("Should allow new owner to relist after NFT transfer (FIXED)", async function () {
            // Step 1: Original seller lists the NFT
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            const originalPrice = ethers.utils.parseEther("100");
            
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                originalPrice,
                ethers.constants.AddressZero
            );
            
            // Verify original listing
            let listing = await propertyMarket.listings(0);
            expect(listing.seller).to.equal(originalSeller.address);
            expect(listing.status).to.equal(0); // LISTED
            expect(listing.price).to.equal(originalPrice);
            
            console.log(`✅ Original seller listed NFT for ${ethers.utils.formatEther(originalPrice)} ETH`);
            
            // Step 2: Original seller transfers NFT to new owner
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);
            
            // Verify NFT ownership transfer
            const currentOwner = await nfti.ownerOf(0);
            expect(currentOwner).to.equal(newOwner.address);
            
            console.log(`✅ NFT transferred from ${originalSeller.address} to ${newOwner.address}`);
            
            // Step 3: New owner should be able to relist (FIXED)
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            const newPrice = ethers.utils.parseEther("150");
            
            // This should succeed after the fix
            await propertyMarket.connect(newOwner).listProperty(
                0,
                newPrice,
                ethers.constants.AddressZero
            );
            
            // Verify new listing
            listing = await propertyMarket.listings(0);
            expect(listing.seller).to.equal(newOwner.address);
            expect(listing.status).to.equal(0); // LISTED
            expect(listing.price).to.equal(newPrice);
            
            console.log(`✅ New owner successfully relisted NFT for ${ethers.utils.formatEther(newPrice)} ETH`);
        });
        
        it("Should cancel existing bids when new owner relists", async function () {
            // Step 1: Original seller lists the NFT
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            const originalPrice = ethers.utils.parseEther("100");
            
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                originalPrice,
                ethers.constants.AddressZero
            );
            
            // Step 2: Buyer places a bid
            const bidAmount = ethers.utils.parseEther("110");
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Verify bid exists
            const bids = await propertyMarket.getActiveBidsForToken(0);
            expect(bids.length).to.equal(1);
            expect(bids[0].isActive).to.equal(true);
            
            console.log(`✅ Buyer placed bid of ${ethers.utils.formatEther(bidAmount)} ETH`);
            
            // Step 3: Transfer NFT to new owner
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);
            
            // Step 4: New owner relists - should cancel existing bids
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            const newPrice = ethers.utils.parseEther("150");
            
            await propertyMarket.connect(newOwner).listProperty(
                0,
                newPrice,
                ethers.constants.AddressZero
            );
            
            // Verify bids were cancelled (should be no active bids)
            const bidsAfterRelist = await propertyMarket.getActiveBidsForToken(0);
            expect(bidsAfterRelist.length).to.equal(0);
            
            console.log(`✅ Existing bids were cancelled when new owner relisted`);
        });
        
        it("Should allow new owner to update listing after transfer", async function () {
            // Step 1: Original seller lists and transfers
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                ethers.utils.parseEther("100"),
                ethers.constants.AddressZero
            );
            
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);
            
            // Step 2: New owner relists
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            await propertyMarket.connect(newOwner).listProperty(
                0,
                ethers.utils.parseEther("150"),
                ethers.constants.AddressZero
            );
            
            // Step 3: New owner should be able to update their listing
            const updatedPrice = ethers.utils.parseEther("200");
            await propertyMarket.connect(newOwner).updateListingBySeller(
                0,
                updatedPrice,
                ethers.constants.AddressZero
            );
            
            // Verify update
            const listing = await propertyMarket.listings(0);
            expect(listing.seller).to.equal(newOwner.address);
            expect(listing.price).to.equal(updatedPrice);
            
            console.log(`✅ New owner successfully updated listing to ${ethers.utils.formatEther(updatedPrice)} ETH`);
        });
        
        it("Should prevent same owner from listing twice", async function () {
            // Step 1: Original seller lists the NFT
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            const originalPrice = ethers.utils.parseEther("100");
            
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                originalPrice,
                ethers.constants.AddressZero
            );
            
            // Step 2: Same owner tries to list again - should fail
            await expect(
                propertyMarket.connect(originalSeller).listProperty(
                    0,
                    ethers.utils.parseEther("150"),
                    ethers.constants.AddressZero
                )
            ).to.be.revertedWith("E102");
            
            console.log(`✅ Same owner correctly prevented from listing twice`);
        });
        
        it("Should handle multiple ownership transfers", async function () {
            // Step 1: Original seller lists
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                ethers.utils.parseEther("100"),
                ethers.constants.AddressZero
            );
            
            // Step 2: Transfer to first new owner
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);
            
            // Step 3: First new owner relists
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            await propertyMarket.connect(newOwner).listProperty(
                0,
                ethers.utils.parseEther("150"),
                ethers.constants.AddressZero
            );
            
            // Step 4: Transfer to second new owner (buyer)
            await nfti.connect(newOwner).transferFrom(newOwner.address, buyer.address, 0);
            
            // Step 5: Second new owner should be able to relist
            await nfti.connect(buyer).approve(propertyMarket.address, 0);
            await propertyMarket.connect(buyer).listProperty(
                0,
                ethers.utils.parseEther("200"),
                ethers.constants.AddressZero
            );
            
            // Verify final listing
            const listing = await propertyMarket.listings(0);
            expect(listing.seller).to.equal(buyer.address);
            expect(listing.price).to.equal(ethers.utils.parseEther("200"));
            
            console.log(`✅ Multiple ownership transfers handled correctly`);
        });
        
        it("Should handle transfer with confirmation period", async function () {
            // Step 1: Original seller lists with confirmation period
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            const confirmationPeriod = 3600; // 1 hour
            
            await propertyMarket.connect(originalSeller).listPropertyWithConfirmation(
                0,
                ethers.utils.parseEther("100"),
                ethers.constants.AddressZero,
                confirmationPeriod
            );
            
            // Step 2: Transfer NFT
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);
            
            // Step 3: New owner should be able to relist with different confirmation period
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            const newConfirmationPeriod = 7200; // 2 hours
            
            await propertyMarket.connect(newOwner).listPropertyWithConfirmation(
                0,
                ethers.utils.parseEther("150"),
                ethers.constants.AddressZero,
                newConfirmationPeriod
            );
            
            // Verify new listing
            const listing = await propertyMarket.listings(0);
            expect(listing.seller).to.equal(newOwner.address);
            expect(listing.confirmationPeriod).to.equal(newConfirmationPeriod);
            
            console.log(`✅ Confirmation period listing handled correctly after transfer`);
        });
    });
    
    describe("🔒 Edge Cases and Security", function () {
        it("Should handle complex ownership chain", async function () {
            // Test multiple transfers and relistings
            // Step 1: Original seller lists
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                ethers.utils.parseEther("100"),
                ethers.constants.AddressZero
            );

            // Step 2: Transfer to first new owner
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);

            // Step 3: First new owner relists
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            await propertyMarket.connect(newOwner).listProperty(
                0,
                ethers.utils.parseEther("150"),
                ethers.constants.AddressZero
            );

            // Step 4: Transfer to second new owner (buyer)
            await nfti.connect(newOwner).transferFrom(newOwner.address, buyer.address, 0);

            // Step 5: Second new owner should be able to relist
            await nfti.connect(buyer).approve(propertyMarket.address, 0);
            await propertyMarket.connect(buyer).listProperty(
                0,
                ethers.utils.parseEther("200"),
                ethers.constants.AddressZero
            );

            // Verify final listing
            const listing = await propertyMarket.listings(0);
            expect(listing.seller).to.equal(buyer.address);
            expect(listing.status).to.equal(0); // LISTED
            expect(listing.price).to.equal(ethers.utils.parseEther("200"));

            console.log(`✅ Complex ownership chain handled correctly`);
        });
        
        it("Should emit correct events for new owner listing", async function () {
            // Step 1: Original listing
            await nfti.connect(originalSeller).approve(propertyMarket.address, 0);
            await propertyMarket.connect(originalSeller).listProperty(
                0,
                ethers.utils.parseEther("100"),
                ethers.constants.AddressZero
            );
            
            // Step 2: Transfer
            await nfti.connect(originalSeller).transferFrom(originalSeller.address, newOwner.address, 0);
            
            // Step 3: New owner relists - check events
            await nfti.connect(newOwner).approve(propertyMarket.address, 0);
            
            await expect(
                propertyMarket.connect(newOwner).listProperty(
                    0,
                    ethers.utils.parseEther("150"),
                    ethers.constants.AddressZero
                )
            ).to.emit(propertyMarket, "NewListing")
             .withArgs(0, newOwner.address, ethers.utils.parseEther("150"), ethers.constants.AddressZero);
            
            console.log(`✅ Correct events emitted for new owner listing`);
        });
    });
});
