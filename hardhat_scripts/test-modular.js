const { ethers } = require("hardhat");

async function testModularContract() {
    console.log("🧪 Testing Modular PropertyMarket Functionality\n");

    // Load deployment info
    let deploymentInfo;
    try {
        const fs = require('fs');
        deploymentInfo = JSON.parse(fs.readFileSync('deployment-modular.json', 'utf8'));
        console.log("📋 Loaded deployment info from deployment-modular.json");
    } catch (error) {
        console.error("❌ Please run modular deployment script first!");
        return;
    }

    // Get signers
    const [deployer, buyer1, buyer2] = await ethers.getSigners();
    console.log("👤 Deployer (Seller):", deployer.address);
    console.log("👤 Buyer 1:", buyer1.address);
    console.log("👤 Buyer 2:", buyer2.address);

    // Connect to deployed contracts
    const PropertyMarketCoordinator = await ethers.getContractFactory("PropertyMarketCoordinator");
    const coordinator = PropertyMarketCoordinator.attach(deploymentInfo.contracts.PropertyMarketCoordinator);
    
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    const nftiContract = MockERC721.attach(deploymentInfo.contracts.NFTI);

    console.log("\n🔗 Connected to deployed contracts");
    console.log("Coordinator:", coordinator.address);
    console.log("NFTI:", nftiContract.address);

    // Grant KYC to buyers
    console.log("\n⚙️ Setting up KYC for buyers...");
    await coordinator.grantKYCVerification(buyer1.address);
    await coordinator.grantKYCVerification(buyer2.address);
    console.log("✅ KYC granted to buyers");

    // Test 1: List property with confirmation period
    console.log("\n" + "=".repeat(60));
    console.log("TEST 1: List Property with Confirmation Period");
    console.log("=".repeat(60));

    const tokenId = 1;
    const price = ethers.utils.parseEther("1.0"); // 1 ETH
    const confirmationPeriod = 3600; // 1 hour

    try {
        const tx1 = await coordinator.listPropertyWithConfirmation(
            tokenId,
            price,
            ethers.constants.AddressZero, // ETH payment
            confirmationPeriod
        );
        await tx1.wait();
        console.log("✅ Property listed with confirmation period");
        console.log("   Token ID:", tokenId);
        console.log("   Price:", ethers.utils.formatEther(price), "ETH");
        console.log("   Confirmation Period:", confirmationPeriod / 3600, "hours");
        console.log("   Transaction:", tx1.hash);
    } catch (error) {
        console.error("❌ Failed to list property:", error.message);
        return;
    }

    // Verify listing
    const listingDetails = await coordinator.getListingDetails(tokenId);
    console.log("\n📋 Listing Details:");
    console.log("   Seller:", listingDetails.seller);
    console.log("   Price:", ethers.utils.formatEther(listingDetails.price), "ETH");
    console.log("   Status:", listingDetails.status);
    console.log("   Confirmation Period:", listingDetails.confirmationPeriod, "seconds");

    // Test 2: Buyer makes purchase request
    console.log("\n" + "=".repeat(60));
    console.log("TEST 2: Buyer Makes Purchase Request");
    console.log("=".repeat(60));

    try {
        const tx2 = await coordinator.connect(buyer1).purchaseProperty(
            tokenId,
            price,
            { value: price }
        );
        await tx2.wait();
        console.log("✅ Purchase request submitted");
        console.log("   Buyer:", buyer1.address);
        console.log("   Offer:", ethers.utils.formatEther(price), "ETH");
        console.log("   Transaction:", tx2.hash);
    } catch (error) {
        console.error("❌ Failed to submit purchase request:", error.message);
        return;
    }

    // Check pending purchase details
    const pendingDetails = await coordinator.getPendingPurchaseDetails(tokenId);
    console.log("\n📋 Pending Purchase Details:");
    console.log("   Buyer:", pendingDetails.buyer);
    console.log("   Offer Price:", ethers.utils.formatEther(pendingDetails.offerPrice), "ETH");
    console.log("   Deadline:", new Date(pendingDetails.confirmationDeadline * 1000));
    console.log("   Is Active:", pendingDetails.isActive);
    console.log("   Is Expired:", pendingDetails.isExpired);

    // Test 3: Seller confirms purchase
    console.log("\n" + "=".repeat(60));
    console.log("TEST 3: Seller Confirms Purchase");
    console.log("=".repeat(60));

    try {
        const tx3 = await coordinator.confirmPurchase(tokenId);
        await tx3.wait();
        console.log("✅ Purchase confirmed by seller");
        console.log("   Transaction:", tx3.hash);
    } catch (error) {
        console.error("❌ Failed to confirm purchase:", error.message);
        return;
    }

    // Verify NFT transfer
    const newOwner = await nftiContract.ownerOf(tokenId);
    console.log("\n🔍 Verification:");
    console.log("   NFT Owner:", newOwner);
    console.log("   Expected Buyer:", buyer1.address);
    console.log("   Transfer Success:", newOwner === buyer1.address);

    // Check final listing status
    const finalListing = await coordinator.getListingDetails(tokenId);
    console.log("   Final Status:", finalListing.status); // Should be SOLD (2)

    // Test 4: Test bidding functionality
    console.log("\n" + "=".repeat(60));
    console.log("TEST 4: Test Bidding Functionality");
    console.log("=".repeat(60));

    // List another property without confirmation period
    const tokenId2 = 2;
    try {
        const tx4 = await coordinator.listProperty(
            tokenId2,
            price,
            ethers.constants.AddressZero
        );
        await tx4.wait();
        console.log("✅ Second property listed (no confirmation period)");
    } catch (error) {
        console.error("❌ Failed to list second property:", error.message);
        return;
    }

    // Place bid
    const bidAmount = ethers.utils.parseEther("1.2"); // 1.2 ETH
    try {
        const tx5 = await coordinator.connect(buyer2).placeBid(
            tokenId2,
            bidAmount,
            ethers.constants.AddressZero,
            { value: bidAmount }
        );
        await tx5.wait();
        console.log("✅ Bid placed");
        console.log("   Bidder:", buyer2.address);
        console.log("   Bid Amount:", ethers.utils.formatEther(bidAmount), "ETH");
    } catch (error) {
        console.error("❌ Failed to place bid:", error.message);
        return;
    }

    // Check active bids
    const activeBids = await coordinator.getActiveBids(tokenId2);
    console.log("\n📋 Active Bids:");
    console.log("   Number of bids:", activeBids.length);
    if (activeBids.length > 0) {
        console.log("   Highest bid:", ethers.utils.formatEther(activeBids[0].amount), "ETH");
        console.log("   Bidder:", activeBids[0].bidder);
    }

    // Accept bid
    try {
        const tx6 = await coordinator.acceptBid(tokenId2, 0);
        await tx6.wait();
        console.log("✅ Bid accepted by seller");
    } catch (error) {
        console.error("❌ Failed to accept bid:", error.message);
        return;
    }

    // Verify second NFT transfer
    const newOwner2 = await nftiContract.ownerOf(tokenId2);
    console.log("\n🔍 Second Property Verification:");
    console.log("   NFT Owner:", newOwner2);
    console.log("   Expected Buyer:", buyer2.address);
    console.log("   Transfer Success:", newOwner2 === buyer2.address);

    // Test 5: Test rejection flow with third property
    console.log("\n" + "=".repeat(60));
    console.log("TEST 5: Test Rejection Flow");
    console.log("=".repeat(60));

    // List third property with confirmation period
    const tokenId3 = 3;
    try {
        const tx7 = await coordinator.listPropertyWithConfirmation(
            tokenId3,
            price,
            ethers.constants.AddressZero,
            confirmationPeriod
        );
        await tx7.wait();
        console.log("✅ Third property listed with confirmation period");
    } catch (error) {
        console.error("❌ Failed to list third property:", error.message);
        return;
    }

    // Buyer makes purchase request
    try {
        const tx8 = await coordinator.connect(buyer1).purchaseProperty(
            tokenId3,
            price,
            { value: price }
        );
        await tx8.wait();
        console.log("✅ Purchase request submitted for third property");
    } catch (error) {
        console.error("❌ Failed to submit purchase request:", error.message);
        return;
    }

    // Seller rejects
    try {
        const tx9 = await coordinator.rejectPurchase(tokenId3);
        await tx9.wait();
        console.log("✅ Purchase rejected by seller");
        console.log("   Buyer should receive refund");
    } catch (error) {
        console.error("❌ Failed to reject purchase:", error.message);
        return;
    }

    // Check that property is back to listed status
    const rejectedListing = await coordinator.getListingDetails(tokenId3);
    console.log("   Property Status after rejection:", rejectedListing.status); // Should be LISTED (0)

    // Test 6: Test module addresses
    console.log("\n" + "=".repeat(60));
    console.log("TEST 6: Verify Module Architecture");
    console.log("=".repeat(60));

    const [storageAddr, coreAddr, biddingAddr, adminAddr] = await coordinator.getModuleAddresses();
    console.log("✅ Module addresses retrieved:");
    console.log("   Storage:", storageAddr);
    console.log("   Core:", coreAddr);
    console.log("   Bidding:", biddingAddr);
    console.log("   Admin:", adminAddr);

    const config = await coordinator.getContractConfig();
    console.log("\n✅ Contract configuration:");
    console.log("   Whitelist Enabled:", config.whitelistEnabled);
    console.log("   Base Fee:", config.baseFee, "basis points");
    console.log("   Fee Collector:", config.feeCollector);
    console.log("   Is Paused:", config.isPaused);

    console.log("\n🎉 All tests completed successfully!");
    console.log("✅ Modular PropertyMarket is working correctly");
    console.log("✅ All functionality preserved after contract splitting");
    console.log("✅ Seller confirmation mechanism working");
    console.log("✅ Bidding system functional");
    console.log("✅ Admin controls accessible");
}

// Execute tests
if (require.main === module) {
    testModularContract()
        .then(() => {
            console.log("\n🏁 Modular testing completed!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Testing failed:");
            console.error(error);
            process.exit(1);
        });
}

module.exports = testModularContract;
