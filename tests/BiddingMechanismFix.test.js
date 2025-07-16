const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Bidding Mechanism Fix", function () {
    let propertyMarket, mockNFTI, mockNFTM;
    let owner, seller, bidder1, bidder2, buyer, admin;
    
    beforeEach(async function () {
        [owner, seller, bidder1, bidder2, buyer, admin] = await ethers.getSigners();
        
        // Deploy mock NFT contracts
        const MockERC721 = await ethers.getContractFactory("MockERC721");
        mockNFTI = await MockERC721.deploy("Property NFT", "NFTI");
        mockNFTM = await MockERC721.deploy("Membership NFT", "NFTM");
        
        // Deploy PropertyMarket
        const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
        propertyMarket = await PropertyMarket.deploy(
            mockNFTI.address,
            mockNFTM.address,
            admin.address,
            admin.address, // fee collector
            admin.address  // rewards vault
        );
        
        // Mint NFTs and approve
        await mockNFTI.mint(seller.address);
        await mockNFTI.connect(seller).approve(propertyMarket.address, 0);
        
        // Set up KYC for all users
        await propertyMarket.connect(admin).setKYCStatus(seller.address, true);
        await propertyMarket.connect(admin).setKYCStatus(bidder1.address, true);
        await propertyMarket.connect(admin).setKYCStatus(bidder2.address, true);
        await propertyMarket.connect(admin).setKYCStatus(buyer.address, true);
        
        // List property
        await propertyMarket.connect(seller).listProperty(
            0, // tokenId
            ethers.utils.parseEther("100"), // 100 ETH
            ethers.constants.AddressZero // ETH payment
        );
    });
    
    describe("Fixed Bidding Logic", function () {
        it("Should allow direct purchase at listing price when no bids exist", async function () {
            const listingPrice = ethers.utils.parseEther("100");
            
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(0, listingPrice, {
                    value: listingPrice
                })
            ).to.not.be.reverted;
            
            // Verify NFT was transferred
            expect(await mockNFTI.ownerOf(0)).to.equal(buyer.address);
        });
        
        it("Should require outbidding when active bids exist", async function () {
            const listingPrice = ethers.utils.parseEther("100");
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place a bid first
            await propertyMarket.connect(bidder1).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Direct purchase at listing price should fail
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(0, listingPrice, {
                    value: listingPrice
                })
            ).to.be.revertedWith("Payment failed");
            
            // Direct purchase must exceed highest bid
            const higherAmount = ethers.utils.parseEther("125");
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(0, higherAmount, {
                    value: higherAmount
                })
            ).to.not.be.reverted;
            
            // Verify NFT was transferred
            expect(await mockNFTI.ownerOf(0)).to.equal(buyer.address);
        });
        
        it("Should emit CompetitivePurchase event when outbidding", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            const purchaseAmount = ethers.utils.parseEther("125");
            
            // Place a bid first
            await propertyMarket.connect(bidder1).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Purchase should emit CompetitivePurchase event
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(0, purchaseAmount, {
                    value: purchaseAmount
                })
            ).to.emit(propertyMarket, "CompetitivePurchase")
             .withArgs(0, buyer.address, purchaseAmount, bidAmount, ethers.constants.AddressZero);
        });
        
        it("Should cancel all bids when property is purchased", async function () {
            const bidAmount1 = ethers.utils.parseEther("120");
            const bidAmount2 = ethers.utils.parseEther("130");
            const purchaseAmount = ethers.utils.parseEther("135");
            
            // Place multiple bids
            await propertyMarket.connect(bidder1).placeBid(
                0,
                bidAmount1,
                ethers.constants.AddressZero,
                { value: bidAmount1 }
            );
            
            await propertyMarket.connect(bidder2).placeBid(
                0,
                bidAmount2,
                ethers.constants.AddressZero,
                { value: bidAmount2 }
            );
            
            // Purchase property
            await propertyMarket.connect(buyer).purchaseProperty(0, purchaseAmount, {
                value: purchaseAmount
            });
            
            // Verify all bids are cancelled
            const [activeBids] = await propertyMarket.getActiveBids(0);
            expect(activeBids.length).to.equal(0);
        });
        
        it("Should maintain fair pricing between bidding and purchasing", async function () {
            const listingPrice = ethers.utils.parseEther("100");
            const bidAmount = ethers.utils.parseEther("120");
            
            // Scenario 1: No bids - purchase at listing price
            await propertyMarket.connect(buyer).purchaseProperty(0, listingPrice, {
                value: listingPrice
            });
            
            // Reset for next test
            await mockNFTI.mint(seller.address);
            await mockNFTI.connect(seller).approve(propertyMarket.address, 1);
            await propertyMarket.connect(seller).listProperty(
                1,
                listingPrice,
                ethers.constants.AddressZero
            );
            
            // Scenario 2: With bids - purchase must exceed highest bid
            await propertyMarket.connect(bidder1).placeBid(
                1,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Purchase at exactly the bid amount should fail (need to exceed)
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(1, bidAmount, {
                    value: bidAmount
                })
            ).to.be.revertedWith("Payment failed");
            
            // Purchase above bid amount should succeed
            const higherAmount = ethers.utils.parseEther("121");
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(1, higherAmount, {
                    value: higherAmount
                })
            ).to.not.be.reverted;
        });
        
        it("Should handle ERC20 token payments correctly", async function () {
            // Deploy mock ERC20
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const mockToken = await MockERC20.deploy("Test Token", "TEST", 18);
            
            // Add token to whitelist
            await propertyMarket.connect(admin).addAllowedToken(mockToken.address);
            
            // Mint tokens to users
            const tokenAmount = ethers.utils.parseEther("1000");
            await mockToken.mint(bidder1.address, tokenAmount);
            await mockToken.mint(buyer.address, tokenAmount);
            
            // Approve spending
            await mockToken.connect(bidder1).approve(propertyMarket.address, tokenAmount);
            await mockToken.connect(buyer).approve(propertyMarket.address, tokenAmount);
            
            // List property with ERC20 payment
            await mockNFTI.mint(seller.address);
            await mockNFTI.connect(seller).approve(propertyMarket.address, 2);
            await propertyMarket.connect(seller).listProperty(
                2,
                ethers.utils.parseEther("100"),
                mockToken.address
            );
            
            // Place bid
            await propertyMarket.connect(bidder1).placeBid(
                2,
                ethers.utils.parseEther("120"),
                mockToken.address
            );
            
            // Purchase must exceed bid
            await expect(
                propertyMarket.connect(buyer).purchaseProperty(
                    2,
                    ethers.utils.parseEther("125")
                )
            ).to.not.be.reverted;
        });
    });
    
    describe("Backward Compatibility", function () {
        it("Should maintain existing bidding functionality", async function () {
            const bidAmount1 = ethers.utils.parseEther("120");
            const bidAmount2 = ethers.utils.parseEther("126"); // 5% increment
            
            // First bid
            await expect(
                propertyMarket.connect(bidder1).placeBid(
                    0,
                    bidAmount1,
                    ethers.constants.AddressZero,
                    { value: bidAmount1 }
                )
            ).to.not.be.reverted;
            
            // Second bid must be 5% higher
            await expect(
                propertyMarket.connect(bidder2).placeBid(
                    0,
                    bidAmount2,
                    ethers.constants.AddressZero,
                    { value: bidAmount2 }
                )
            ).to.not.be.reverted;
        });
        
        it("Should allow seller to accept bids as before", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place bid
            await propertyMarket.connect(bidder1).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Seller accepts bid
            await expect(
                propertyMarket.connect(seller).acceptBid(
                    0,
                    0, // bid index
                    bidder1.address,
                    bidAmount,
                    ethers.constants.AddressZero
                )
            ).to.not.be.reverted;
            
            // Verify NFT was transferred
            expect(await mockNFTI.ownerOf(0)).to.equal(bidder1.address);
        });
    });
});
