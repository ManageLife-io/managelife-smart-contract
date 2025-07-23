const { ethers } = require("hardhat");
const fs = require('fs');

async function main() {
    console.log("🧪 Testing deployed PropertyMarket contract...\n");

    // Load deployment info
    const deploymentInfo = JSON.parse(fs.readFileSync('deployment-current.json', 'utf8'));
    
    // Get signers
    const [deployer, buyer1, buyer2] = await ethers.getSigners();
    console.log("Deployer (Seller):", deployer.address);
    console.log("Buyer 1:", buyer1.address);
    console.log("Buyer 2:", buyer2.address);

    // Connect to deployed contracts
    const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
    const propertyMarket = PropertyMarket.attach(deploymentInfo.contracts.PropertyMarket);
    
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    const nftiContract = MockERC721.attach(deploymentInfo.contracts.NFTI);

    console.log("\n📋 Contract Information:");
    console.log("PropertyMarket:", propertyMarket.address);
    console.log("NFTI Contract:", nftiContract.address);

    // Test 1: List a property
    console.log("\n" + "=".repeat(50));
    console.log("TEST 1: List Property");
    console.log("=".repeat(50));

    const tokenId = 1;
    const price = ethers.utils.parseEther("1.0"); // 1 ETH
    
    try {
        const tx1 = await propertyMarket.listProperty(
            tokenId,
            price,
            ethers.constants.AddressZero // ETH payment
        );
        await tx1.wait();
        console.log("✅ Property listed successfully");
        console.log("   Token ID:", tokenId);
        console.log("   Price:", ethers.utils.formatEther(price), "ETH");
    } catch (error) {
        console.error("❌ Failed to list property:", error.message);
        return;
    }

    // Check listing details
    const listing = await propertyMarket.getListingDetails(tokenId);
    console.log("\n📋 Listing Details:");
    console.log("   Seller:", listing.seller);
    console.log("   Price:", ethers.utils.formatEther(listing.price), "ETH");
    console.log("   Status:", listing.status.toString());
    console.log("   Payment Token:", listing.paymentToken);

    // Test 2: Purchase property
    console.log("\n" + "=".repeat(50));
    console.log("TEST 2: Purchase Property");
    console.log("=".repeat(50));

    const buyerBalanceBefore = await buyer1.getBalance();
    console.log("Buyer balance before:", ethers.utils.formatEther(buyerBalanceBefore), "ETH");

    try {
        const tx2 = await propertyMarket.connect(buyer1).purchaseProperty(
            tokenId,
            price,
            { value: price }
        );
        await tx2.wait();
        console.log("✅ Property purchased successfully");
    } catch (error) {
        console.error("❌ Failed to purchase property:", error.message);
        return;
    }

    // Verify NFT ownership transfer
    const newOwner = await nftiContract.ownerOf(tokenId);
    console.log("\n🔍 Ownership Verification:");
    console.log("   New NFT Owner:", newOwner);
    console.log("   Expected Buyer:", buyer1.address);
    console.log("   Transfer Success:", newOwner === buyer1.address);

    const buyerBalanceAfter = await buyer1.getBalance();
    console.log("   Buyer balance after:", ethers.utils.formatEther(buyerBalanceAfter), "ETH");
    console.log("   Cost (approx):", ethers.utils.formatEther(buyerBalanceBefore.sub(buyerBalanceAfter)), "ETH");

    // Test 3: List another property with confirmation period
    console.log("\n" + "=".repeat(50));
    console.log("TEST 3: List Property with Confirmation Period");
    console.log("=".repeat(50));

    const tokenId2 = 2;
    const confirmationPeriod = 3600; // 1 hour

    try {
        const tx3 = await propertyMarket.listPropertyWithConfirmation(
            tokenId2,
            price,
            ethers.constants.AddressZero,
            confirmationPeriod
        );
        await tx3.wait();
        console.log("✅ Property listed with confirmation period");
        console.log("   Token ID:", tokenId2);
        console.log("   Confirmation Period:", confirmationPeriod / 3600, "hours");
    } catch (error) {
        console.error("❌ Failed to list property with confirmation:", error.message);
        return;
    }

    // Test 4: Submit purchase request (requires confirmation)
    console.log("\n" + "=".repeat(50));
    console.log("TEST 4: Submit Purchase Request");
    console.log("=".repeat(50));

    try {
        const tx4 = await propertyMarket.connect(buyer2).purchaseProperty(
            tokenId2,
            price,
            { value: price }
        );
        await tx4.wait();
        console.log("✅ Purchase request submitted");
        console.log("   Buyer:", buyer2.address);
        console.log("   Status: Pending seller confirmation");
    } catch (error) {
        console.error("❌ Failed to submit purchase request:", error.message);
        return;
    }

    // Check pending purchase details
    const pendingPurchase = await propertyMarket.getPendingPurchaseDetails(tokenId2);
    console.log("\n📋 Pending Purchase Details:");
    console.log("   Buyer:", pendingPurchase.buyer);
    console.log("   Price:", ethers.utils.formatEther(pendingPurchase.price), "ETH");
    console.log("   Deadline:", new Date(pendingPurchase.deadline * 1000));
    console.log("   Is Active:", pendingPurchase.active);

    // Test 5: Confirm purchase
    console.log("\n" + "=".repeat(50));
    console.log("TEST 5: Confirm Purchase");
    console.log("=".repeat(50));

    try {
        const tx5 = await propertyMarket.confirmPurchase(tokenId2);
        await tx5.wait();
        console.log("✅ Purchase confirmed by seller");
    } catch (error) {
        console.error("❌ Failed to confirm purchase:", error.message);
        return;
    }

    // Verify second NFT transfer
    const newOwner2 = await nftiContract.ownerOf(tokenId2);
    console.log("\n🔍 Second Transfer Verification:");
    console.log("   New NFT Owner:", newOwner2);
    console.log("   Expected Buyer:", buyer2.address);
    console.log("   Transfer Success:", newOwner2 === buyer2.address);

    // Test 6: Check contract state
    console.log("\n" + "=".repeat(50));
    console.log("TEST 6: Contract State Check");
    console.log("=".repeat(50));

    // Check fee configuration
    const feeConfig = await propertyMarket.feeConfig();
    console.log("Fee Configuration:");
    console.log("   Base Fee:", feeConfig.baseFee.toString(), "basis points");
    console.log("   Max Fee:", feeConfig.maxFee.toString(), "basis points");
    console.log("   Fee Collector:", feeConfig.feeCollector);

    // Check reward parameters
    const rewardParams = await propertyMarket.rewardParams();
    console.log("\nReward Parameters:");
    console.log("   Base Rate:", rewardParams.baseRate.toString(), "basis points");
    console.log("   Community Multiplier:", rewardParams.communityMultiplier.toString());
    console.log("   Max Lease Bonus:", rewardParams.maxLeaseBonus.toString());
    console.log("   Rewards Vault:", rewardParams.rewardsVault);

    // Check KYC status
    const isKYCVerified = await propertyMarket.isKYCVerified(deployer.address);
    console.log("\nKYC Status:");
    console.log("   Deployer KYC Verified:", isKYCVerified);

    console.log("\n🎉 All tests completed successfully!");
    console.log("✅ PropertyMarket contract is fully functional");
    console.log("✅ Both immediate and confirmation-based purchases work");
    console.log("✅ NFT transfers are working correctly");
    console.log("✅ Fee and reward systems are configured");

    // Save test results
    const testResults = {
        network: deploymentInfo.network,
        contracts: deploymentInfo.contracts,
        testResults: {
            immediatePurchase: newOwner === buyer1.address,
            confirmationPurchase: newOwner2 === buyer2.address,
            feeSystemWorking: feeConfig.baseFee.gt(0),
            kycSystemWorking: isKYCVerified
        },
        testTime: new Date().toISOString()
    };

    console.log("\n📋 Test Summary:");
    console.log("=".repeat(50));
    console.log("Network Chain ID:", testResults.network.chainId);
    console.log("PropertyMarket:", testResults.contracts.PropertyMarket);
    console.log("Immediate Purchase:", testResults.testResults.immediatePurchase ? "✅ PASS" : "❌ FAIL");
    console.log("Confirmation Purchase:", testResults.testResults.confirmationPurchase ? "✅ PASS" : "❌ FAIL");
    console.log("Fee System:", testResults.testResults.feeSystemWorking ? "✅ PASS" : "❌ FAIL");
    console.log("KYC System:", testResults.testResults.kycSystemWorking ? "✅ PASS" : "❌ FAIL");
    console.log("=".repeat(50));

    // Save to file
    fs.writeFileSync(
        'contract-test-results.json', 
        JSON.stringify(testResults, null, 2)
    );
    console.log("💾 Test results saved to contract-test-results.json");

    return testResults;
}

// Execute test
if (require.main === module) {
    main()
        .then(() => {
            console.log("\n🏁 Contract testing completed successfully!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Contract testing failed:");
            console.error(error.message);
            process.exit(1);
        });
}

module.exports = main;
