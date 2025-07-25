const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MA2-08: Double Refund Vulnerability Fix", function () {
    let propertyMarket;
    let nfti;
    let lifeToken;
    let owner, seller, buyer, feeCollector;

    beforeEach(async function () {
        [owner, seller, buyer, feeCollector] = await ethers.getSigners();

        // Deploy LifeToken
        const LifeToken = await ethers.getContractFactory("LifeToken");
        lifeToken = await LifeToken.deploy(owner.address);
        await lifeToken.deployed();

        // Deploy MockERC721 for testing
        const MockERC721 = await ethers.getContractFactory("MockERC721");
        nfti = await MockERC721.deploy("Test NFT", "TNFT");
        await nfti.deployed();

        // Deploy PropertyMarket
        const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
        propertyMarket = await PropertyMarket.deploy(
            nfti.address,
            nfti.address, // Using same address for nftm for simplicity
            owner.address, // initialAdmin
            feeCollector.address, // feeCollector
            feeCollector.address // rewardsVault (using same address for simplicity)
        );
        await propertyMarket.deployed();

        // Setup: Mint NFT and approve market
        await nfti.connect(owner).mintWithId(seller.address, 0);
        await nfti.connect(seller).approve(propertyMarket.address, 0);

        // Grant KYC verification to seller and buyer
        await propertyMarket.connect(owner).batchApproveKYC([seller.address, buyer.address], true);

        // List property
        const listingPrice = ethers.utils.parseEther("100");
        await propertyMarket.connect(seller).listProperty(
            0,
            listingPrice,
            ethers.constants.AddressZero
        );
        
        // Place bid
        const bidAmount = ethers.utils.parseEther("120");
        await propertyMarket.connect(buyer).placeBid(
            0,
            bidAmount,
            ethers.constants.AddressZero,
            { value: bidAmount }
        );
        
        // Accept bid (creates PENDING_PAYMENT status)
        await propertyMarket.connect(seller).acceptBid(
            0, 1, buyer.address, bidAmount, ethers.constants.AddressZero
        );
    });
    
    describe("🔒 Double Refund Prevention", function () {
        it("Should NOT double refund excess ETH in completeBidPayment", async function () {
            const bidAmount = ethers.utils.parseEther("120");

            // Record initial balances
            const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);
            const contractBalanceBefore = await ethers.provider.getBalance(propertyMarket.address);

            // Complete payment without sending additional ETH (uses locked funds from placeBid)
            const tx = await propertyMarket.connect(buyer).completeBidPayment(0);
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);

            // Record final balances
            const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
            const contractBalanceAfter = await ethers.provider.getBalance(propertyMarket.address);

            // Calculate actual cost to buyer (should only be gas)
            const actualCost = buyerBalanceBefore.sub(buyerBalanceAfter).sub(gasUsed);

            // Verify buyer paid no additional ETH (funds were already locked)
            expect(actualCost).to.equal(0, "Buyer should pay no additional ETH");

            // Verify contract balance decreased correctly (bid amount was already locked from placeBid)
            const contractDecrease = contractBalanceBefore.sub(contractBalanceAfter);
            expect(contractDecrease).to.equal(bidAmount, "Contract should lose exactly the bid amount");

            console.log(`✅ Bid amount: ${ethers.utils.formatEther(bidAmount)} ETH`);
            console.log(`✅ Additional cost to buyer: ${ethers.utils.formatEther(actualCost)} ETH`);
            console.log(`✅ Contract balance change: ${ethers.utils.formatEther(contractDecrease)} ETH`);
        });
        
        it("Should handle payment completion without additional funds", async function () {
            const bidAmount = ethers.utils.parseEther("120");

            // Record initial balances
            const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);
            const contractBalanceBefore = await ethers.provider.getBalance(propertyMarket.address);

            // Complete payment without sending additional ETH
            const tx = await propertyMarket.connect(buyer).completeBidPayment(0);
            const receipt = await tx.wait();
            const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);

            // Record final balances
            const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
            const contractBalanceAfter = await ethers.provider.getBalance(propertyMarket.address);

            // Verify buyer only paid gas
            const expectedBalance = buyerBalanceBefore.sub(gasUsed);
            expect(buyerBalanceAfter).to.equal(expectedBalance, "Buyer should only pay gas");

            // Verify contract balance decreased correctly
            const contractDecrease = contractBalanceBefore.sub(contractBalanceAfter);
            expect(contractDecrease).to.equal(bidAmount, "Contract should lose exactly the bid amount");

            console.log(`✅ Payment completed using locked funds`);
            console.log(`✅ Buyer only paid gas fees`);
        });
        
        it("Should prevent contract balance drain attack", async function () {
            // Add some ETH to contract to simulate other users' funds
            await owner.sendTransaction({
                to: propertyMarket.address,
                value: ethers.utils.parseEther("1000")
            });

            const bidAmount = ethers.utils.parseEther("120");

            const contractBalanceBefore = await ethers.provider.getBalance(propertyMarket.address);

            // Complete payment without additional ETH (no drain possible due to fix)
            await propertyMarket.connect(buyer).completeBidPayment(0);

            const contractBalanceAfter = await ethers.provider.getBalance(propertyMarket.address);

            // Verify contract didn't lose more than the bid amount
            const contractDecrease = contractBalanceBefore.sub(contractBalanceAfter);
            expect(contractDecrease).to.equal(bidAmount, "Contract should only lose the bid amount");

            // Verify contract still has most of its original balance
            const remainingBalance = contractBalanceAfter;
            const expectedRemaining = ethers.utils.parseEther("1000").sub(bidAmount);
            expect(remainingBalance).to.be.gte(expectedRemaining, "Contract should retain other users' funds");

            console.log(`✅ Contract balance protected from drain attack`);
            console.log(`✅ Remaining balance: ${ethers.utils.formatEther(remainingBalance)} ETH`);
        });
    });
    
    describe("🧪 Edge Cases", function () {
        it("Should reject any additional payment to prevent double refund vulnerability", async function () {
            const additionalPayment = ethers.BigNumber.from("1"); // 1 wei

            // Attempt to send any additional payment should be rejected
            await expect(
                propertyMarket.connect(buyer).completeBidPayment(0, {
                    value: additionalPayment
                })
            ).to.be.revertedWith("No additional payment required");

            console.log(`✅ Additional payment correctly rejected to prevent vulnerability`);
        });
    });
});
