const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Simple Audit Fixes Test", function () {
    let lifeToken;
    let owner, user1;
    
    beforeEach(async function () {
        [owner, user1] = await ethers.getSigners();
        
        // Deploy LifeToken
        const LifeToken = await ethers.getContractFactory("LifeToken");
        lifeToken = await LifeToken.deploy(owner.address);
        await lifeToken.deployed();
    });
    
    describe("LifeToken Rebase Protection", function () {
        it("Should enforce 20% maximum change limit", async function () {
            // Fast forward time by 31 days
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Get current rebase factor
            const rebaseConfig = await lifeToken.rebaseConfig();
            const currentFactor = rebaseConfig.rebaseFactor;
            
            // Try to rebase by more than 20% (should fail)
            const tooHighFactor = currentFactor.mul(130).div(100); // 30% increase
            
            await expect(
                lifeToken.connect(owner).rebase(tooHighFactor)
            ).to.be.revertedWith("Rebase change exceeds maximum allowed (20%)");
        });
        
        it("Should allow rebase within 20% limit", async function () {
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Get current rebase factor
            const rebaseConfig = await lifeToken.rebaseConfig();
            const currentFactor = rebaseConfig.rebaseFactor;
            
            // Rebase by 15% (should succeed)
            const validFactor = currentFactor.mul(115).div(100); // 15% increase
            
            await expect(
                lifeToken.connect(owner).rebase(validFactor)
            ).to.emit(lifeToken, "Rebase");
        });
        
        it("Should allow emergency rebase to bypass limits", async function () {
            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            // Get current rebase factor
            const rebaseConfig = await lifeToken.rebaseConfig();
            const currentFactor = rebaseConfig.rebaseFactor;
            
            // Emergency rebase by 50% (should succeed)
            const emergencyFactor = currentFactor.mul(150).div(100); // 50% increase
            
            await expect(
                lifeToken.connect(owner).emergencyRebase(emergencyFactor)
            ).to.emit(lifeToken, "EmergencyRebase");
        });
        
        it("Should not allow non-owner to call emergency rebase", async function () {
            await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");
            
            const rebaseConfig = await lifeToken.rebaseConfig();
            const currentFactor = rebaseConfig.rebaseFactor;
            const emergencyFactor = currentFactor.mul(150).div(100);
            
            await expect(
                lifeToken.connect(user1).emergencyRebase(emergencyFactor)
            ).to.be.revertedWith("Ownable: caller is not the owner");
        });
    });
    
    describe("Basic LifeToken Functions", function () {
        it("Should have correct initial configuration", async function () {
            const rebaseConfig = await lifeToken.rebaseConfig();
            expect(rebaseConfig.rebaseFactor).to.equal(ethers.utils.parseEther("1"));
            expect(rebaseConfig.epoch).to.equal(0);
        });
        
        it("Should have correct total supply", async function () {
            const totalSupply = await lifeToken.totalSupply();
            const expectedSupply = ethers.utils.parseEther("2000000000"); // 2 billion
            expect(totalSupply).to.equal(expectedSupply);
        });
        
        it("Should allow owner to set rebaser", async function () {
            await expect(
                lifeToken.connect(owner).setRebaser(user1.address)
            ).to.emit(lifeToken, "RebaserUpdated");
            
            expect(await lifeToken.rebaser()).to.equal(user1.address);
        });
    });
});
