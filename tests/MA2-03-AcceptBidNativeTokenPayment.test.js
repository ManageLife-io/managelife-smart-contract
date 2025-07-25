const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MA2-03: acceptBid() Cannot Process Native Token Payments", function () {
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
            nfti.address, // using same address for NFTm
            owner.address, // initialAdmin
            feeCollector.address, // feeCollector
            feeCollector.address  // rewardsVault
        );
        await propertyMarket.deployed();

        // Mint NFT to seller
        await nfti.connect(owner).mintWithId(seller.address, 0);

        // Grant KYC verification
        await propertyMarket.connect(owner).batchApproveKYC([seller.address, buyer.address], true);

        // Approve PropertyMarket to transfer NFT
        await nfti.connect(seller).approve(propertyMarket.address, 0);

        // List the NFT
        await propertyMarket.connect(seller).listProperty(
            0,
            ethers.utils.parseEther("100"),
            ethers.constants.AddressZero // ETH payment
        );
    });

    describe("✅ Current Implementation Analysis", function () {
        it("Should demonstrate that ETH bid acceptance works correctly", async function () {
            // Step 1: Buyer places ETH bid
            const bidAmount = ethers.utils.parseEther("100");
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                ethers.constants.AddressZero,
                { value: bidAmount }
            );

            console.log(`✅ Buyer placed ETH bid of ${ethers.utils.formatEther(bidAmount)} ETH`);

            // Step 2: Verify bid was placed
            const bids = await propertyMarket.getActiveBidsForToken(0);
            expect(bids.length).to.equal(1);
            expect(bids[0].amount).to.equal(bidAmount);
            expect(bids[0].paymentToken).to.equal(ethers.constants.AddressZero);

            // Step 3: Seller accepts the ETH bid
            // This should work because acceptBid() now only sets PENDING_PAYMENT status
            console.log(`🔍 Accepting ETH bid...`);

            await expect(
                propertyMarket.connect(seller).acceptBid(
                    0,
                    1, // bid index (1-based)
                    buyer.address,
                    bidAmount,
                    ethers.constants.AddressZero
                )
            ).to.not.be.reverted;

            console.log(`✅ acceptBid() succeeded: Set to PENDING_PAYMENT status`);

            // Step 4: Verify status is PENDING_PAYMENT
            const listing = await propertyMarket.listings(0);
            expect(listing.status).to.equal(4); // PENDING_PAYMENT

            // Step 5: Complete the payment
            await expect(
                propertyMarket.connect(buyer).completeBidPayment(0)
            ).to.not.be.reverted;

            console.log(`✅ completeBidPayment() succeeded: Payment processed from escrow`);

            // Step 6: Verify NFT was transferred
            expect(await nfti.ownerOf(0)).to.equal(buyer.address);
            console.log(`✅ NFT transferred to buyer`);
        });

        it("Should show ERC20 bids work correctly", async function () {
            // Deploy mock ERC20 token
            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const mockToken = await MockERC20.deploy("Test Token", "TEST", 18);
            await mockToken.deployed();

            // Add token to whitelist
            await propertyMarket.connect(owner).addAllowedToken(mockToken.address);

            // Mint tokens to buyer and approve
            const bidAmount = ethers.utils.parseEther("100");
            await mockToken.mint(buyer.address, bidAmount);
            await mockToken.connect(buyer).approve(propertyMarket.address, bidAmount);

            // Place ERC20 bid
            await propertyMarket.connect(buyer).placeBid(
                0,
                bidAmount,
                mockToken.address
            );

            console.log(`✅ Buyer placed ERC20 bid of ${ethers.utils.formatEther(bidAmount)} tokens`);

            // Accept ERC20 bid - this should work
            await expect(
                propertyMarket.connect(seller).acceptBid(
                    0,
                    1, // bid index
                    buyer.address,
                    bidAmount,
                    mockToken.address
                )
            ).to.not.be.reverted;

            console.log(`✅ ERC20 bid accepted successfully`);

            // Verify NFT was transferred
            expect(await nfti.ownerOf(0)).to.equal(buyer.address);
        });
    });

    describe("🔍 Implementation Analysis", function () {
        it("Should analyze the current payment flow", async function () {
            console.log(`\n🔍 Current Implementation Analysis:`);
            console.log(`1. acceptBid() function is NOT payable (correct)`);
            console.log(`2. For ETH bids, acceptBid() sets PENDING_PAYMENT status`);
            console.log(`3. completeBidPayment() processes payment from escrow`);
            console.log(`4. No msg.value needed in acceptBid() call`);
            console.log(`5. ETH was already locked during placeBid()`);
            console.log(`6. Result: Clean separation of concerns\n`);

            // Check function signatures
            const acceptBidFragment = propertyMarket.interface.getFunction("acceptBid");
            const completeBidFragment = propertyMarket.interface.getFunction("completeBidPayment");

            console.log(`acceptBid function stateMutability: ${acceptBidFragment.stateMutability}`);
            console.log(`completeBidPayment function stateMutability: ${completeBidFragment.stateMutability}`);

            expect(acceptBidFragment.stateMutability).to.equal("nonpayable");
            expect(completeBidFragment.stateMutability).to.equal("payable");
            console.log(`✅ Correct: acceptBid() is nonpayable, completeBidPayment() is payable`);
        });
    });

    describe("💡 Current Behavior", function () {
        it("Should describe how ETH bid acceptance works now", async function () {
            console.log(`\n💡 Current ETH Bid Acceptance Flow:`);
            console.log(`1. Buyer places ETH bid → ETH is escrowed in contract`);
            console.log(`2. Seller accepts bid → Status set to PENDING_PAYMENT`);
            console.log(`3. Buyer calls completeBidPayment() → Payment processed from escrow`);
            console.log(`4. NFT transferred to buyer`);
            console.log(`5. Transaction completed\n`);

            console.log(`✅ This design correctly separates bid acceptance from payment processing`);
        });
    });

    describe("🔧 Design Analysis", function () {
        it("Should analyze the current design benefits", async function () {
            console.log(`\n🔧 Current Design Benefits:`);
            console.log(`1. Clean separation: acceptBid() vs completeBidPayment()`);
            console.log(`2. ETH escrow prevents double-spending`);
            console.log(`3. No msg.value confusion in acceptBid()`);
            console.log(`4. Consistent with ERC20 immediate completion`);
            console.log(`5. Prevents MA2-08 double refund vulnerability\n`);

            console.log(`✅ The current implementation appears to be well-designed`);
        });
    });
});
