const { ethers } = require("hardhat");
const fs = require('fs');

async function main() {
    console.log("🧪 Testing PENDING_SELLER_CONFIRMATION with fresh NFT...\n");

    // Load deployment info
    let deploymentInfo;
    try {
        deploymentInfo = JSON.parse(fs.readFileSync('deployment-current.json', 'utf8'));
    } catch (error) {
        console.error("❌ Please run deploy-current.js first to deploy the contract");
        return;
    }
    
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

    // Helper function to get property status name
    function getStatusName(status) {
        const statuses = ['LISTED', 'RENTED', 'SOLD', 'DELISTED', 'PENDING_PAYMENT', 'PENDING_SELLER_CONFIRMATION'];
        return statuses[status] || 'UNKNOWN';
    }

    // Step 1: Mint a fresh NFT for testing
    console.log("\n" + "=".repeat(60));
    console.log("STEP 1: Mint Fresh NFT for Testing");
    console.log("=".repeat(60));

    const newTokenId = Math.floor(Math.random() * 10000) + 1000; // Use a random high number to avoid conflicts
    console.log("🎲 Using random token ID:", newTokenId);
    
    try {
        const mintTx = await nftiContract.mintWithId(deployer.address, newTokenId);
        await mintTx.wait();
        console.log("✅ Minted new NFT with ID:", newTokenId);
        
        // Verify ownership
        const owner = await nftiContract.ownerOf(newTokenId);
        console.log("   Owner:", owner);
        console.log("   Ownership correct:", owner === deployer.address);
        
        // Approve marketplace
        const isApproved = await nftiContract.isApprovedForAll(deployer.address, propertyMarket.address);
        if (!isApproved) {
            await nftiContract.setApprovalForAll(propertyMarket.address, true);
            console.log("✅ Approved marketplace for NFT transfers");
        } else {
            console.log("✅ Marketplace already approved");
        }
    } catch (error) {
        console.error("❌ Failed to mint NFT:", error.message);
        return;
    }

    // Step 2: List with seller confirmation required
    console.log("\n" + "=".repeat(60));
    console.log("STEP 2: List Property with Seller Confirmation Required");
    console.log("=".repeat(60));

    const price = ethers.utils.parseEther("2.0"); // 2 ETH
    const confirmationPeriod = 3600; // 1 hour
    
    try {
        // Ensure seller has KYC
        const isKYCVerified = await propertyMarket.isKYCVerified(deployer.address);
        if (!isKYCVerified) {
            console.log("⚙️ Granting KYC verification to seller...");
            await propertyMarket.batchApproveKYC([deployer.address], true);
        }

        const listTx = await propertyMarket.listPropertyWithConfirmation(
            newTokenId,
            price,
            ethers.constants.AddressZero, // ETH payment
            confirmationPeriod
        );
        await listTx.wait();
        console.log("✅ Property listed with seller confirmation requirement");
        console.log("   Token ID:", newTokenId);
        console.log("   Price:", ethers.utils.formatEther(price), "ETH");
        console.log("   Confirmation Period:", confirmationPeriod / 3600, "hours");
    } catch (error) {
        console.error("❌ Failed to list property:", error.message);
        return;
    }

    // Verify listing
    const listing = await propertyMarket.getListingDetails(newTokenId);
    console.log("\n📋 Listing Details:");
    console.log("   Status:", getStatusName(listing.status), `(${listing.status})`);
    console.log("   Seller:", listing.seller);
    console.log("   Price:", ethers.utils.formatEther(listing.price), "ETH");

    // Step 3: Buyer submits purchase request
    console.log("\n" + "=".repeat(60));
    console.log("STEP 3: Buyer Submits Purchase Request");
    console.log("=".repeat(60));

    const buyerBalanceBefore = await buyer1.getBalance();
    console.log("Buyer balance before:", ethers.utils.formatEther(buyerBalanceBefore), "ETH");

    try {
        // Ensure buyer has KYC
        const isBuyerKYCVerified = await propertyMarket.isKYCVerified(buyer1.address);
        if (!isBuyerKYCVerified) {
            console.log("⚙️ Granting KYC verification to buyer...");
            await propertyMarket.batchApproveKYC([buyer1.address], true);
        }

        const purchaseTx = await propertyMarket.connect(buyer1).purchaseProperty(
            newTokenId,
            price,
            { value: price }
        );
        await purchaseTx.wait();
        console.log("✅ Purchase request submitted successfully");
        console.log("   Buyer:", buyer1.address);
        console.log("   Amount paid:", ethers.utils.formatEther(price), "ETH");
    } catch (error) {
        console.error("❌ Failed to submit purchase request:", error.message);
        
        // Detailed error analysis
        console.log("\n🔍 Error Analysis:");
        if (error.message.includes('E403')) {
            console.log("   E403 error detected - analyzing...");
            
            // Check various conditions
            const buyerKYC = await propertyMarket.isKYCVerified(buyer1.address);
            const sellerKYC = await propertyMarket.isKYCVerified(deployer.address);
            const isPaused = await propertyMarket.paused();
            const nftOwner = await nftiContract.ownerOf(newTokenId);
            const isApproved = await nftiContract.isApprovedForAll(deployer.address, propertyMarket.address);
            
            console.log("   Buyer KYC verified:", buyerKYC);
            console.log("   Seller KYC verified:", sellerKYC);
            console.log("   Contract paused:", isPaused);
            console.log("   NFT owner:", nftOwner);
            console.log("   Expected seller:", deployer.address);
            console.log("   NFT approved:", isApproved);
            
            const currentListing = await propertyMarket.getListingDetails(newTokenId);
            console.log("   Listing status:", getStatusName(currentListing.status));
            console.log("   Listed seller:", currentListing.seller);
        }
        return;
    }

    // Check status after purchase request
    const postPurchaseListing = await propertyMarket.getListingDetails(newTokenId);
    console.log("\n📋 Status After Purchase Request:");
    console.log("   Status:", getStatusName(postPurchaseListing.status), `(${postPurchaseListing.status})`);

    // Check if we have pending purchase details
    try {
        const pendingPurchase = await propertyMarket.getPendingPurchaseDetails(newTokenId);
        console.log("\n📋 Pending Purchase Details:");
        console.log("   Buyer:", pendingPurchase.buyer);
        console.log("   Offer Price:", ethers.utils.formatEther(pendingPurchase.offerPrice), "ETH");
        console.log("   Payment Token:", pendingPurchase.paymentToken);
        console.log("   Purchase Timestamp:", new Date(pendingPurchase.purchaseTimestamp * 1000));
        console.log("   Confirmation Deadline:", new Date(pendingPurchase.confirmationDeadline * 1000));
        console.log("   Is Active:", pendingPurchase.isActive);
        console.log("   Is Expired:", pendingPurchase.isExpired);

        // Store for later use in global scope
        global.pendingPurchaseData = pendingPurchase;
    } catch (error) {
        console.log("\n📋 Error getting pending purchase details:", error.message);
        console.log("   This might indicate immediate purchase or error in setup");
    }

    const buyerBalanceAfter = await buyer1.getBalance();
    console.log("\n💰 Balance Changes:");
    console.log("   Buyer balance after:", ethers.utils.formatEther(buyerBalanceAfter), "ETH");
    console.log("   Amount spent:", ethers.utils.formatEther(buyerBalanceBefore.sub(buyerBalanceAfter)), "ETH");

    // Check NFT ownership
    const currentNFTOwner = await nftiContract.ownerOf(newTokenId);
    console.log("\n🏠 NFT Ownership:");
    console.log("   Current owner:", currentNFTOwner);
    console.log("   Original seller:", deployer.address);
    console.log("   Expected buyer:", buyer1.address);
    console.log("   Transferred to buyer:", currentNFTOwner === buyer1.address);

    // Step 4: Try to confirm purchase (if there's a pending purchase)
    console.log("\n" + "=".repeat(60));
    console.log("STEP 4: Attempt to Confirm Purchase");
    console.log("=".repeat(60));

    try {
        // Check if there's a pending purchase first
        const pendingPurchase = await propertyMarket.getPendingPurchaseDetails(newTokenId);
        console.log("🔍 Checking pending purchase for confirmation:");
        console.log("   Buyer:", pendingPurchase.buyer);
        console.log("   Is Active:", pendingPurchase.isActive);
        console.log("   Offer Price:", ethers.utils.formatEther(pendingPurchase.offerPrice), "ETH");

        if (pendingPurchase.isActive) {
            console.log("📋 Confirming pending purchase...");
            console.log("   Pending amount:", ethers.utils.formatEther(pendingPurchase.offerPrice), "ETH");

            // Try confirming without sending ETH first
            try {
                const confirmTx = await propertyMarket.confirmPurchase(newTokenId);
                await confirmTx.wait();
                console.log("✅ Purchase confirmed by seller (no additional ETH required)");
            } catch (confirmError) {
                console.log("❌ Failed to confirm without ETH:", confirmError.message);

                if (confirmError.message.includes("Insufficient ETH sent")) {
                    console.log("🔄 Trying to confirm with ETH amount...");
                    try {
                        const confirmTxWithETH = await propertyMarket.confirmPurchase(newTokenId, {
                            value: pendingPurchase.offerPrice
                        });
                        await confirmTxWithETH.wait();
                        console.log("✅ Purchase confirmed by seller (with ETH sent)");
                    } catch (ethError) {
                        console.log("❌ Failed to confirm with ETH:", ethError.message);
                    }
                } else {
                    console.log("❌ Other confirmation error:", confirmError.message);
                }
            }
        } else {
            console.log("❌ No active pending purchase found");
        }
    } catch (error) {
        console.log("❌ Failed to check/confirm purchase:", error.message);
        console.log("   This might indicate the purchase was immediate or already completed");
    }

    // Final status check
    const finalListing = await propertyMarket.getListingDetails(newTokenId);
    const finalNFTOwner = await nftiContract.ownerOf(newTokenId);
    
    console.log("\n📋 Final Status:");
    console.log("   Listing Status:", getStatusName(finalListing.status), `(${finalListing.status})`);
    console.log("   NFT Owner:", finalNFTOwner);
    console.log("   Purchase Successful:", finalNFTOwner === buyer1.address);

    // Determine what type of purchase this was
    if (finalNFTOwner === buyer1.address) {
        if (postPurchaseListing.status === 5) { // PENDING_SELLER_CONFIRMATION
            console.log("\n🎉 SUCCESS: PENDING_SELLER_CONFIRMATION flow worked!");
        } else if (postPurchaseListing.status === 2) { // SOLD
            console.log("\n✅ SUCCESS: Immediate purchase flow worked!");
            console.log("   Note: This was an immediate purchase, not a confirmation-based one");
        }
    } else {
        console.log("\n❌ Purchase flow did not complete successfully");
    }

    // Save test results
    const testResults = {
        network: deploymentInfo.network,
        contracts: deploymentInfo.contracts,
        testResults: {
            nftMinted: true,
            propertyListed: true,
            purchaseSubmitted: finalNFTOwner === buyer1.address,
            wasConfirmationBased: postPurchaseListing.status === 5,
            wasImmediate: postPurchaseListing.status === 2,
            finalOwnershipCorrect: finalNFTOwner === buyer1.address
        },
        testTime: new Date().toISOString()
    };

    console.log("\n📋 Test Summary:");
    console.log("=".repeat(50));
    console.log("NFT Minted:", testResults.testResults.nftMinted ? "✅ PASS" : "❌ FAIL");
    console.log("Property Listed:", testResults.testResults.propertyListed ? "✅ PASS" : "❌ FAIL");
    console.log("Purchase Submitted:", testResults.testResults.purchaseSubmitted ? "✅ PASS" : "❌ FAIL");
    console.log("Was Confirmation-Based:", testResults.testResults.wasConfirmationBased ? "✅ YES" : "❌ NO");
    console.log("Was Immediate:", testResults.testResults.wasImmediate ? "✅ YES" : "❌ NO");
    console.log("Final Ownership Correct:", testResults.testResults.finalOwnershipCorrect ? "✅ PASS" : "❌ FAIL");
    console.log("=".repeat(50));

    fs.writeFileSync(
        'fresh-confirmation-test-results.json', 
        JSON.stringify(testResults, null, 2)
    );
    console.log("💾 Test results saved to fresh-confirmation-test-results.json");

    return testResults;
}

// Execute test
if (require.main === module) {
    main()
        .then(() => {
            console.log("\n🏁 Fresh confirmation testing completed!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Fresh confirmation testing failed:");
            console.error(error.message);
            process.exit(1);
        });
}

module.exports = main;
