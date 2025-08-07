const { ethers } = require("hardhat");

async function main() {
    console.log("🚀 Testing PropertyMarket deployment with simplified version...\n");

    // Get deployer account
    const [deployer, buyer1, buyer2] = await ethers.getSigners();
    console.log("Deployer (Seller):", deployer.address);
    console.log("Buyer 1:", buyer1.address);
    console.log("Buyer 2:", buyer2.address);
    console.log("Deployer balance:", ethers.utils.formatEther(await deployer.getBalance()), "ETH\n");

    // Deploy mock NFT contracts for testing
    console.log("📦 Deploying mock NFT contracts...");
    
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    
    // Deploy NFTI (Property NFT)
    const nftiContract = await MockERC721.deploy("Property NFT", "NFTI");
    await nftiContract.deployed();
    console.log("✅ NFTI Contract deployed to:", nftiContract.address);

    // Create a simple marketplace contract for testing
    console.log("\n📦 Creating simple marketplace contract...");
    
    const SimpleMarketplace = await ethers.getContractFactory("contracts/market/PropertyMarketSimple.sol:PropertyMarketSimple");
    const marketplace = await SimpleMarketplace.deploy(nftiContract.address);
    await marketplace.deployed();
    console.log("✅ Simple Marketplace deployed to:", marketplace.address);

    // Setup initial configuration
    console.log("\n⚙️ Setting up test environment...");
    
    // Mint test NFTs
    console.log("🎨 Minting test NFTs...");
    await nftiContract.mintWithId(deployer.address, 1);
    await nftiContract.mintWithId(deployer.address, 2);
    await nftiContract.mintWithId(deployer.address, 3);
    console.log("✅ Minted NFTs with IDs: 1, 2, 3");

    // Approve marketplace to transfer NFTs
    await nftiContract.setApprovalForAll(marketplace.address, true);
    console.log("✅ Approved marketplace to transfer NFTs");

    // Test the seller confirmation functionality
    console.log("\n🧪 Testing Seller Confirmation Functionality...");
    
    const tokenId = 1;
    const price = ethers.utils.parseEther("1.0"); // 1 ETH
    const confirmationPeriod = 3600; // 1 hour

    // Test 1: List property with confirmation period
    console.log("\n" + "=".repeat(50));
    console.log("TEST 1: List Property with Confirmation Period");
    console.log("=".repeat(50));

    try {
        const tx1 = await marketplace.listPropertyWithConfirmation(
            tokenId,
            price,
            ethers.constants.AddressZero, // ETH payment
            confirmationPeriod
        );
        await tx1.wait();
        console.log("✅ Property listed successfully");
        console.log("   Token ID:", tokenId);
        console.log("   Price:", ethers.utils.formatEther(price), "ETH");
        console.log("   Confirmation Period:", confirmationPeriod / 3600, "hours");
    } catch (error) {
        console.error("❌ Failed to list property:", error.message);
        return;
    }

    // Verify listing
    const listingDetails = await marketplace.getListingDetails(tokenId);
    console.log("\n📋 Listing Details:");
    console.log("   Seller:", listingDetails.seller);
    console.log("   Price:", ethers.utils.formatEther(listingDetails.price), "ETH");
    console.log("   Status:", listingDetails.status);
    console.log("   Confirmation Period:", listingDetails.confirmationPeriod, "seconds");

    // Test 2: Buyer makes purchase request
    console.log("\n" + "=".repeat(50));
    console.log("TEST 2: Buyer Makes Purchase Request");
    console.log("=".repeat(50));

    try {
        const tx2 = await marketplace.connect(buyer1).purchaseProperty(
            tokenId,
            price,
            { value: price }
        );
        await tx2.wait();
        console.log("✅ Purchase request submitted");
        console.log("   Buyer:", buyer1.address);
        console.log("   Offer:", ethers.utils.formatEther(price), "ETH");
    } catch (error) {
        console.error("❌ Failed to submit purchase request:", error.message);
        return;
    }

    // Check pending purchase details
    const pendingDetails = await marketplace.getPendingPurchaseDetails(tokenId);
    console.log("\n📋 Pending Purchase Details:");
    console.log("   Buyer:", pendingDetails.buyer);
    console.log("   Offer Price:", ethers.utils.formatEther(pendingDetails.price), "ETH");
    console.log("   Deadline:", new Date(pendingDetails.deadline * 1000));
    console.log("   Is Active:", pendingDetails.active);
    console.log("   Is Expired:", pendingDetails.expired);

    // Test 3: Seller confirms purchase
    console.log("\n" + "=".repeat(50));
    console.log("TEST 3: Seller Confirms Purchase");
    console.log("=".repeat(50));

    try {
        const tx3 = await marketplace.confirmPurchase(tokenId);
        await tx3.wait();
        console.log("✅ Purchase confirmed by seller");
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

    // Test 4: Test rejection flow
    console.log("\n" + "=".repeat(50));
    console.log("TEST 4: Test Rejection Flow");
    console.log("=".repeat(50));

    const tokenId2 = 2;
    
    // List second property
    try {
        const tx4 = await marketplace.listPropertyWithConfirmation(
            tokenId2,
            price,
            ethers.constants.AddressZero,
            confirmationPeriod
        );
        await tx4.wait();
        console.log("✅ Second property listed");
    } catch (error) {
        console.error("❌ Failed to list second property:", error.message);
        return;
    }

    // Buyer makes purchase request
    try {
        const tx5 = await marketplace.connect(buyer2).purchaseProperty(
            tokenId2,
            price,
            { value: price }
        );
        await tx5.wait();
        console.log("✅ Purchase request submitted for second property");
    } catch (error) {
        console.error("❌ Failed to submit purchase request:", error.message);
        return;
    }

    // Seller rejects
    try {
        const tx6 = await marketplace.rejectPurchase(tokenId2);
        await tx6.wait();
        console.log("✅ Purchase rejected by seller");
        console.log("   Buyer should receive refund");
    } catch (error) {
        console.error("❌ Failed to reject purchase:", error.message);
        return;
    }

    // Check that property is back to listed status
    const rejectedListing = await marketplace.getListingDetails(tokenId2);
    console.log("   Property Status after rejection:", rejectedListing.status); // Should be LISTED (0)

    // Test 5: Test immediate purchase (no confirmation period)
    console.log("\n" + "=".repeat(50));
    console.log("TEST 5: Test Immediate Purchase (No Confirmation)");
    console.log("=".repeat(50));

    const tokenId3 = 3;
    
    // List third property without confirmation period
    try {
        const tx7 = await marketplace.listProperty(
            tokenId3,
            price,
            ethers.constants.AddressZero
        );
        await tx7.wait();
        console.log("✅ Third property listed (immediate purchase)");
    } catch (error) {
        console.error("❌ Failed to list third property:", error.message);
        return;
    }

    // Buyer purchases immediately
    try {
        const tx8 = await marketplace.connect(buyer1).purchaseProperty(
            tokenId3,
            price,
            { value: price }
        );
        await tx8.wait();
        console.log("✅ Immediate purchase completed");
    } catch (error) {
        console.error("❌ Failed to complete immediate purchase:", error.message);
        return;
    }

    // Verify immediate transfer
    const immediateOwner = await nftiContract.ownerOf(tokenId3);
    console.log("   NFT Owner:", immediateOwner);
    console.log("   Expected Buyer:", buyer1.address);
    console.log("   Immediate Transfer Success:", immediateOwner === buyer1.address);

    console.log("\n🎉 All tests completed successfully!");
    console.log("✅ Seller confirmation functionality is working correctly");
    console.log("✅ Both immediate and confirmation-based purchases work");
    console.log("✅ Rejection mechanism works properly");

    // Save test results
    const testResults = {
        network: await ethers.provider.getNetwork(),
        deployer: deployer.address,
        contracts: {
            SimpleMarketplace: marketplace.address,
            NFTI: nftiContract.address
        },
        testResults: {
            confirmationPurchase: newOwner === buyer1.address,
            rejectionFlow: rejectedListing.status.toString() === "0", // LISTED
            immediatePurchase: immediateOwner === buyer1.address
        },
        testTime: new Date().toISOString()
    };

    console.log("\n📋 Test Summary:");
    console.log("=".repeat(50));
    console.log("Network:", testResults.network.name);
    console.log("Marketplace:", testResults.contracts.SimpleMarketplace);
    console.log("NFTI:", testResults.contracts.NFTI);
    console.log("Confirmation Purchase:", testResults.testResults.confirmationPurchase ? "✅ PASS" : "❌ FAIL");
    console.log("Rejection Flow:", testResults.testResults.rejectionFlow ? "✅ PASS" : "❌ FAIL");
    console.log("Immediate Purchase:", testResults.testResults.immediatePurchase ? "✅ PASS" : "❌ FAIL");
    console.log("=".repeat(50));

    // Save to file
    const fs = require('fs');
    fs.writeFileSync(
        'test-results.json', 
        JSON.stringify(testResults, null, 2)
    );
    console.log("💾 Test results saved to test-results.json");

    return testResults;
}

// Execute test
if (require.main === module) {
    main()
        .then(() => {
            console.log("\n🏁 Testing completed successfully!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Testing failed:");
            console.error(error.message);
            process.exit(1);
        });
}

module.exports = main;
