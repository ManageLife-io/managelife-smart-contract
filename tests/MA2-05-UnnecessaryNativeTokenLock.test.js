const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MA2-05: Unnecessary Native Token Lock Fix", function () {
    let propertyMarket;
    let nfti;
    let owner, seller, buyer, feeCollector;
    
    beforeEach(async function () {
        [owner, seller, buyer, feeCollector] = await ethers.getSigners();
        
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
        
        // Setup: Mint NFT and approve market
        await nfti.connect(owner).mintWithId(seller.address, 0);
        await nfti.connect(seller).approve(propertyMarket.address, 0);
        
        // Grant KYC verification
        await propertyMarket.connect(owner).batchApproveKYC([seller.address, buyer.address], true);
        
        // List property
        const listingPrice = ethers.utils.parseEther("1");
        await propertyMarket.connect(seller).listProperty(
            0,
            listingPrice,
            ethers.constants.AddressZero // ETH
        );
    });
    
    describe("🔒 placeBid() Function - Already Fixed", function () {
        it("Should only require additional ETH for bid increases", async function () {
            const initialBid = ethers.utils.parseEther("1.2");
            const increasedBid = ethers.utils.parseEther("1.5");
            const additionalAmount = increasedBid.sub(initialBid);
            
            // Record initial buyer balance
            const buyerBalanceBefore = await buyer.getBalance();
            
            // Place initial bid
            const tx1 = await propertyMarket.connect(buyer).placeBid(
                0,
                initialBid,
                ethers.constants.AddressZero,
                { value: initialBid }
            );
            const receipt1 = await tx1.wait();
            const gasCost1 = receipt1.gasUsed.mul(receipt1.effectiveGasPrice);
            
            // Check contract balance after first bid
            const contractBalanceAfterFirst = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalanceAfterFirst).to.equal(initialBid);
            
            // Increase bid - should only require additional amount
            const tx2 = await propertyMarket.connect(buyer).placeBid(
                0,
                increasedBid,
                ethers.constants.AddressZero,
                { value: additionalAmount }
            );
            const receipt2 = await tx2.wait();
            const gasCost2 = receipt2.gasUsed.mul(receipt2.effectiveGasPrice);
            
            // Check contract balance after bid increase
            const contractBalanceAfterIncrease = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalanceAfterIncrease).to.equal(increasedBid);
            
            // Verify buyer only paid the additional amount (plus gas)
            const buyerBalanceAfter = await buyer.getBalance();
            const totalSpent = buyerBalanceBefore.sub(buyerBalanceAfter);
            const expectedSpent = initialBid.add(additionalAmount).add(gasCost1).add(gasCost2);
            
            expect(totalSpent).to.be.closeTo(expectedSpent, ethers.utils.parseEther("0.01"));
            
            console.log(`✅ Initial bid: ${ethers.utils.formatEther(initialBid)} ETH`);
            console.log(`✅ Additional amount: ${ethers.utils.formatEther(additionalAmount)} ETH`);
            console.log(`✅ Total locked: ${ethers.utils.formatEther(contractBalanceAfterIncrease)} ETH`);
        });
        
        it("Should not require any ETH for same amount bid", async function () {
            const bidAmount = ethers.utils.parseEther("1.2");
            
            // Place initial bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Try to place same bid again - should not require any ETH
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: 0 }
            );
            
            // Contract should still only have the original bid amount
            const contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bidAmount);
            
            console.log(`✅ Same bid amount handled correctly`);
        });
    });
    
    describe("🔧 placeBidSecure() Function - Fixed", function () {
        it("Should only require additional ETH for bid increases (FIXED)", async function () {
            const initialBid = ethers.utils.parseEther("1.2");
            const increasedBid = ethers.utils.parseEther("1.5");
            const additionalAmount = increasedBid.sub(initialBid);
            
            // Record initial buyer balance
            const buyerBalanceBefore = await buyer.getBalance();
            
            // Place initial bid using placeBidSecure
            const tx1 = await propertyMarket.connect(buyer).placeBidSecure(
                0,
                initialBid,
                ethers.constants.AddressZero,
                { value: initialBid }
            );
            const receipt1 = await tx1.wait();
            const gasCost1 = receipt1.gasUsed.mul(receipt1.effectiveGasPrice);
            
            // Check contract balance after first bid
            const contractBalanceAfterFirst = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalanceAfterFirst).to.equal(initialBid);
            
            // Increase bid - should only require additional amount (FIXED)
            const tx2 = await propertyMarket.connect(buyer).placeBidSecure(
                0,
                increasedBid,
                ethers.constants.AddressZero,
                { value: additionalAmount }
            );
            const receipt2 = await tx2.wait();
            const gasCost2 = receipt2.gasUsed.mul(receipt2.effectiveGasPrice);
            
            // Check contract balance after bid increase
            const contractBalanceAfterIncrease = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalanceAfterIncrease).to.equal(increasedBid);
            
            // Verify buyer only paid the additional amount (plus gas)
            const buyerBalanceAfter = await buyer.getBalance();
            const totalSpent = buyerBalanceBefore.sub(buyerBalanceAfter);
            const expectedSpent = initialBid.add(additionalAmount).add(gasCost1).add(gasCost2);
            
            expect(totalSpent).to.be.closeTo(expectedSpent, ethers.utils.parseEther("0.01"));
            
            console.log(`✅ placeBidSecure - Initial bid: ${ethers.utils.formatEther(initialBid)} ETH`);
            console.log(`✅ placeBidSecure - Additional amount: ${ethers.utils.formatEther(additionalAmount)} ETH`);
            console.log(`✅ placeBidSecure - Total locked: ${ethers.utils.formatEther(contractBalanceAfterIncrease)} ETH`);
        });
        
        it("Should not require any ETH for same amount bid (FIXED)", async function () {
            const bidAmount = ethers.utils.parseEther("1.2");
            
            // Place initial bid using placeBidSecure
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Try to place same bid again - should not require any ETH (FIXED)
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: 0 }
            );
            
            // Contract should still only have the original bid amount
            const contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bidAmount);
            
            console.log(`✅ placeBidSecure - Same bid amount handled correctly`);
        });
        
        it("Should require full amount for new bids", async function () {
            const bidAmount = ethers.utils.parseEther("1.2");
            
            // Place new bid - should require full amount
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Contract should have the full bid amount
            const contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bidAmount);
            
            console.log(`✅ placeBidSecure - New bid requires full amount correctly`);
        });
        
        it("Should reject insufficient additional ETH", async function () {
            const initialBid = ethers.utils.parseEther("1.2");
            const increasedBid = ethers.utils.parseEther("1.5");
            const insufficientAmount = ethers.utils.parseEther("0.1"); // Less than required 0.3 ETH
            
            // Place initial bid
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                initialBid,
                ethers.constants.AddressZero,
                { value: initialBid }
            );
            
            // Try to increase bid with insufficient additional ETH - should fail
            await expect(
                propertyMarket.connect(buyer).placeBidSecure(
                    0,
                    increasedBid,
                    ethers.constants.AddressZero,
                    { value: insufficientAmount }
                )
            ).to.be.revertedWith("Must send exact additional amount");
            
            console.log(`✅ placeBidSecure - Correctly rejects insufficient additional ETH`);
        });
    });
    
    describe("🔒 Contract Balance Verification", function () {
        it("Should maintain correct contract balance across multiple bid updates", async function () {
            const bid1 = ethers.utils.parseEther("1.2");
            const bid2 = ethers.utils.parseEther("1.5");
            const bid3 = ethers.utils.parseEther("1.8");
            
            // Place initial bid
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bid1,
                ethers.constants.AddressZero,
                { value: bid1 }
            );
            
            let contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bid1);
            
            // Increase to bid2
            const additional1 = bid2.sub(bid1);
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bid2,
                ethers.constants.AddressZero,
                { value: additional1 }
            );
            
            contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bid2);
            
            // Increase to bid3
            const additional2 = bid3.sub(bid2);
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bid3,
                ethers.constants.AddressZero,
                { value: additional2 }
            );
            
            contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bid3);
            
            console.log(`✅ Contract balance correctly maintained through multiple updates`);
            console.log(`   Final balance: ${ethers.utils.formatEther(contractBalance)} ETH`);
        });
        
        it("Should handle bid cancellation correctly", async function () {
            const bidAmount = ethers.utils.parseEther("1.2");
            
            // Place bid
            await propertyMarket.connect(buyer).placeBidSecure(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Verify contract has the bid amount
            let contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bidAmount);
            
            // Cancel bid
            await propertyMarket.connect(buyer).cancelBid(0);
            
            // Contract should be empty after cancellation
            contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(0);
            
            console.log(`✅ Contract balance correctly reset after bid cancellation`);
        });
    });
});
