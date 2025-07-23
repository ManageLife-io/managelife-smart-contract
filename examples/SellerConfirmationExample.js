// Seller confirmation period functionality usage example

const { ethers } = require("ethers");

class SellerConfirmationExample {
    constructor(propertyMarketContract, provider) {
        this.propertyMarket = propertyMarketContract;
        this.provider = provider;
    }

    // 1. Seller lists property with confirmation time setting
    async listPropertyWithConfirmation(tokenId, price, paymentToken, confirmationHours = 24) {
        const confirmationPeriod = confirmationHours * 3600; // Convert to seconds
        
        try {
            const tx = await this.propertyMarket.listPropertyWithConfirmation(
                tokenId,
                ethers.utils.parseEther(price.toString()),
                paymentToken,
                confirmationPeriod
            );
            
            console.log(`Property ${tokenId} listed, price: ${price} ETH`);
            console.log(`Seller confirmation time: ${confirmationHours} hours`);
            console.log(`Transaction hash: ${tx.hash}`);

            return tx;
        } catch (error) {
            console.error("Listing failed:", error.message);
            throw error;
        }
    }

    // 2. Buyer initiates purchase request
    async requestPurchase(tokenId, offerPrice) {
        try {
            const tx = await this.propertyMarket.purchaseProperty(
                tokenId,
                ethers.utils.parseEther(offerPrice.toString()),
                { value: ethers.utils.parseEther(offerPrice.toString()) }
            );
            
            console.log(`Purchase request sent, property ${tokenId}, offer: ${offerPrice} ETH`);
            console.log(`Waiting for seller confirmation...`);
            console.log(`Transaction hash: ${tx.hash}`);

            return tx;
        } catch (error) {
            console.error("Purchase request failed:", error.message);
            throw error;
        }
    }

    // 3. Seller confirms purchase
    async confirmPurchase(tokenId) {
        try {
            const tx = await this.propertyMarket.confirmPurchase(tokenId);
            
            console.log(`Seller confirmed purchase, property ${tokenId} transaction completed`);
            console.log(`Transaction hash: ${tx.hash}`);

            return tx;
        } catch (error) {
            console.error("Purchase confirmation failed:", error.message);
            throw error;
        }
    }

    // 4. Seller rejects purchase
    async rejectPurchase(tokenId) {
        try {
            const tx = await this.propertyMarket.rejectPurchase(tokenId);
            
            console.log(`Seller rejected purchase, property ${tokenId} restored to listing status`);
            console.log(`Buyer funds refunded`);
            console.log(`Transaction hash: ${tx.hash}`);

            return tx;
        } catch (error) {
            console.error("Purchase rejection failed:", error.message);
            throw error;
        }
    }

    // 5. Cancel expired purchase order
    async cancelExpiredPurchase(tokenId) {
        try {
            const tx = await this.propertyMarket.cancelExpiredPurchase(tokenId);
            
            console.log(`Expired purchase order cancelled, property ${tokenId}`);
            console.log(`Buyer funds refunded`);
            console.log(`Transaction hash: ${tx.hash}`);

            return tx;
        } catch (error) {
            console.error("Cancel expired order failed:", error.message);
            throw error;
        }
    }

    // 6. Query pending purchase order
    async getPendingPurchaseInfo(tokenId) {
        try {
            const details = await this.propertyMarket.getPendingPurchaseDetails(tokenId);
            
            const info = {
                buyer: details.buyer,
                offerPrice: ethers.utils.formatEther(details.offerPrice),
                paymentToken: details.paymentToken,
                purchaseTime: new Date(details.purchaseTimestamp * 1000),
                deadline: new Date(details.confirmationDeadline * 1000),
                isActive: details.isActive,
                isExpired: details.isExpired
            };
            
            console.log(`Pending purchase order info:`, info);
            return info;
        } catch (error) {
            console.error("Query failed:", error.message);
            throw error;
        }
    }

    // 7. Listen to related events
    setupEventListeners() {
        // Listen to purchase request events
        this.propertyMarket.on("PurchaseRequested", (tokenId, buyer, offerPrice, paymentToken, deadline) => {
            console.log(`🔔 New purchase request:`);
            console.log(`  Property ID: ${tokenId}`);
            console.log(`  Buyer: ${buyer}`);
            console.log(`  Offer: ${ethers.utils.formatEther(offerPrice)} ETH`);
            console.log(`  Confirmation deadline: ${new Date(deadline * 1000)}`);
        });

        // Listen to purchase confirmation events
        this.propertyMarket.on("PurchaseConfirmed", (tokenId, seller, buyer, finalPrice, paymentToken) => {
            console.log(`✅ Purchase confirmed:`);
            console.log(`  Property ID: ${tokenId}`);
            console.log(`  Seller: ${seller}`);
            console.log(`  Buyer: ${buyer}`);
            console.log(`  Final price: ${ethers.utils.formatEther(finalPrice)} ETH`);
        });

        // Listen to purchase rejection events
        this.propertyMarket.on("PurchaseRejected", (tokenId, seller, buyer, offerPrice, paymentToken) => {
            console.log(`❌ Purchase rejected:`);
            console.log(`  Property ID: ${tokenId}`);
            console.log(`  Seller: ${seller}`);
            console.log(`  Buyer: ${buyer}`);
            console.log(`  Offer: ${ethers.utils.formatEther(offerPrice)} ETH`);
        });

        // Listen to purchase expiration events
        this.propertyMarket.on("PurchaseExpired", (tokenId, buyer, offerPrice, paymentToken) => {
            console.log(`⏰ Purchase order expired:`);
            console.log(`  Property ID: ${tokenId}`);
            console.log(`  Buyer: ${buyer}`);
            console.log(`  Offer: ${ethers.utils.formatEther(offerPrice)} ETH`);
        });
    }
}

// Usage example
async function example() {
    // Assuming already connected to contract
    const propertyMarket = new ethers.Contract(contractAddress, abi, signer);
    const example = new SellerConfirmationExample(propertyMarket, provider);

    // Setup event listeners
    example.setupEventListeners();

    // 1. Seller lists property with 24-hour confirmation time
    await example.listPropertyWithConfirmation(1, 100, ethers.constants.AddressZero, 24);

    // 2. Buyer initiates purchase request
    await example.requestPurchase(1, 100);

    // 3. Query pending order
    await example.getPendingPurchaseInfo(1);

    // 4. Seller can choose to confirm or reject
    // await example.confirmPurchase(1);  // Confirm
    // await example.rejectPurchase(1);   // Reject
}

module.exports = SellerConfirmationExample;
