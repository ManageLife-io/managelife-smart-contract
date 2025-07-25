const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Audit Fixes Verification", function () {
    let propertyMarket, lifeToken, nftm, mockNFTI, mockNFTM, adminControl;
    let owner, rebaser, operator, user1, user2, admin;
    
    beforeEach(async function () {
        [owner, rebaser, operator, user1, user2, admin] = await ethers.getSigners();
        
        // Deploy mock contracts
        const MockERC721 = await ethers.getContractFactory("MockERC721");
        mockNFTI = await MockERC721.deploy("Property NFT", "NFTI");
        mockNFTM = await MockERC721.deploy("Membership NFT", "NFTM");
        
        // Deploy AdminControl
        const AdminControl = await ethers.getContractFactory("AdminControl");
        adminControl = await AdminControl.deploy(admin.address, admin.address, admin.address);
        
        // Deploy PropertyMarket
        const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
        propertyMarket = await PropertyMarket.deploy(
            mockNFTI.address,
            mockNFTM.address,
            admin.address,
            admin.address,
            admin.address
        );
        
        // Deploy LifeToken
        const LifeToken = await ethers.getContractFactory("LifeToken");
        lifeToken = await LifeToken.deploy(owner.address);
        
        // Deploy NFTm
        const NFTm = await ethers.getContractFactory("NFTm");
        nftm = await NFTm.deploy(adminControl.address, owner.address, mockNFTI.address);
        
        // Setup
        await mockNFTI.mint(user1.address);
        await mockNFTI.connect(user1).approve(propertyMarket.address, 0);
        await propertyMarket.connect(admin).setKYCStatus(user1.address, true);
        await propertyMarket.connect(admin).setKYCStatus(user2.address, true);
        
        // List property
        await propertyMarket.connect(user1).listProperty(
            0,
            ethers.utils.parseEther("100"),
            ethers.constants.AddressZero
        );
    });
    
    describe("Fix 1: PropertyMarket ETH Bidding Logic", function () {
        it("Should lock ETH when placing bid (no immediate refund)", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            const initialBalance = await user2.getBalance();
            
            const tx = await propertyMarket.connect(user2).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);
            const finalBalance = await user2.getBalance();
            
            // User should have paid the bid amount + gas
            const expectedBalance = initialBalance.sub(bidAmount).sub(gasUsed);
            expect(finalBalance).to.be.closeTo(expectedBalance, ethers.utils.parseEther("0.001"));
            
            // Contract should hold the ETH
            const contractBalance = await ethers.provider.getBalance(propertyMarket.address);
            expect(contractBalance).to.equal(bidAmount);
        });
        
        it("Should refund ETH when bid is cancelled", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place bid
            await propertyMarket.connect(user2).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            const balanceBeforeCancel = await user2.getBalance();
            
            // Cancel bid
            const tx = await propertyMarket.connect(user2).cancelBid(0);
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);
            
            const balanceAfterCancel = await user2.getBalance();
            
            // User should receive refund minus gas
            const expectedBalance = balanceBeforeCancel.add(bidAmount).sub(gasUsed);
            expect(balanceAfterCancel).to.be.closeTo(expectedBalance, ethers.utils.parseEther("0.001"));
        });
        
        it("Should refund all bids when property is sold", async function () {
            const bidAmount1 = ethers.utils.parseEther("120");
            const bidAmount2 = ethers.utils.parseEther("130");
            
            // Place multiple bids
            await propertyMarket.connect(user2).placeBid(
                0,
                bidAmount1,
                ethers.constants.AddressZero,
                { value: bidAmount1 }
            );
            
            const [, , , , buyer] = await ethers.getSigners();
            await propertyMarket.connect(admin).setKYCStatus(buyer.address, true);
            
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount2,
                ethers.constants.AddressZero,
                { value: bidAmount2 }
            );
            
            const user2BalanceBefore = await user2.getBalance();
            const buyerBalanceBefore = await buyer.getBalance();
            
            // Direct purchase should trigger refunds
            const purchaseAmount = ethers.utils.parseEther("135");
            await propertyMarket.connect(buyer).purchaseProperty(0, purchaseAmount, {
                value: purchaseAmount
            });
            
            // Check that bids were refunded (approximately, accounting for gas)
            const user2BalanceAfter = await user2.getBalance();
            const buyerBalanceAfter = await buyer.getBalance();
            
            expect(user2BalanceAfter).to.be.gt(user2BalanceBefore);
            // Buyer should have paid more due to purchase
            expect(buyerBalanceAfter).to.be.lt(buyerBalanceBefore);
        });
    });
    
    describe("Fix 2: LifeToken Rebase Protection", function () {
        it("Should enforce 20% maximum change limit", async function () {
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Try to rebase by more than 20% (should fail)
            const currentFactor = await lifeToken.rebaseConfig().then(config => config.rebaseFactor);
            const tooHighFactor = currentFactor.mul(130).div(100); // 30% increase
            
            await expect(
                lifeToken.connect(owner).rebase(tooHighFactor)
            ).to.be.revertedWith("Rebase change exceeds maximum allowed (20%)");
        });
        
        it("Should allow rebase within 20% limit", async function () {
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Rebase by 15% (should succeed)
            const currentFactor = await lifeToken.rebaseConfig().then(config => config.rebaseFactor);
            const validFactor = currentFactor.mul(115).div(100); // 15% increase
            
            await expect(
                lifeToken.connect(owner).rebase(validFactor)
            ).to.emit(lifeToken, "Rebase");
        });
        
        it("Should allow emergency rebase to bypass limits", async function () {
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Emergency rebase by 50% (should succeed)
            const currentFactor = await lifeToken.rebaseConfig().then(config => config.rebaseFactor);
            const emergencyFactor = currentFactor.mul(150).div(100); // 50% increase
            
            await expect(
                lifeToken.connect(owner).emergencyRebase(emergencyFactor)
            ).to.emit(lifeToken, "EmergencyRebase");
        });
        
        it("Should not allow non-owner to call emergency rebase", async function () {
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            const currentFactor = await lifeToken.rebaseConfig().then(config => config.rebaseFactor);
            const emergencyFactor = currentFactor.mul(150).div(100);
            
            await expect(
                lifeToken.connect(user1).emergencyRebase(emergencyFactor)
            ).to.be.revertedWith("Ownable: caller is not the owner");
        });
    });
    
    describe("Fix 3: NFTm Permission Checks", function () {
        it("Should allow minting with simplified permission check", async function () {
            // Grant operator role
            await adminControl.connect(admin).grantRole(
                ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OPERATOR_ROLE")),
                operator.address
            );
            
            const legalInfo = {
                LLCNumber: "LLC123",
                jurisdiction: "US",
                registryDate: Math.floor(Date.now() / 1000)
            };
            
            await expect(
                nftm.connect(operator).mintPropertyNFT(
                    user1.address,
                    "https://example.com/token/1",
                    legalInfo,
                    0
                )
            ).to.not.be.reverted;
        });
        
        it("Should restrict handleNFTiBurn to operator role", async function () {
            // Should fail for regular admin
            await expect(
                nftm.connect(admin).handleNFTiBurn(0)
            ).to.be.revertedWith("Unauthorized: only NFTi contract or operator");
            
            // Grant operator role and try again
            await adminControl.connect(admin).grantRole(
                ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OPERATOR_ROLE")),
                operator.address
            );
            
            await expect(
                nftm.connect(operator).handleNFTiBurn(0)
            ).to.not.be.reverted;
        });
    });
    
    describe("Integration Tests", function () {
        it("Should handle complete bidding flow with fixes", async function () {
            const bidAmount = ethers.utils.parseEther("120");
            
            // Place bid (ETH locked)
            await propertyMarket.connect(user2).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );
            
            // Accept bid
            await propertyMarket.connect(user1).acceptBid(
                0, 0, user2.address, bidAmount, ethers.constants.AddressZero
            );
            
            // Complete payment
            await propertyMarket.connect(user2).completeBidPayment(0, {
                value: bidAmount
            });
            
            // Verify NFT transfer
            expect(await mockNFTI.ownerOf(0)).to.equal(user2.address);
        });
    });
});
