const { ethers } = require("hardhat");

async function main() {
    console.log("🔧 Checking contract compilation...\n");

    try {
        // Check PropertyMarket compilation
        console.log("📦 Compiling PropertyMarket...");
        const PropertyMarket = await ethers.getContractFactory("PropertyMarket");
        console.log("✅ PropertyMarket compiled successfully");

        // Check PropertyMarketOptimized compilation
        console.log("📦 Compiling PropertyMarketOptimized...");
        const PropertyMarketOptimized = await ethers.getContractFactory("PropertyMarketOptimized");
        console.log("✅ PropertyMarketOptimized compiled successfully");

        // Check modular contracts compilation
        console.log("📦 Compiling modular contracts...");
        const PropertyMarketStorage = await ethers.getContractFactory("PropertyMarketStorage");
        const PropertyMarketCore = await ethers.getContractFactory("PropertyMarketCore");
        const PropertyMarketBidding = await ethers.getContractFactory("PropertyMarketBidding");
        const PropertyMarketAdmin = await ethers.getContractFactory("PropertyMarketAdmin");
        const PropertyMarketCoordinator = await ethers.getContractFactory("PropertyMarketCoordinator");
        console.log("✅ All modular contracts compiled successfully");
        
        // Check MockERC721 compilation
        console.log("📦 Compiling MockERC721...");
        const MockERC721 = await ethers.getContractFactory("MockERC721");
        console.log("✅ MockERC721 compiled successfully");
        
        // Get contract bytecode sizes
        const propertyMarketBytecode = PropertyMarket.bytecode;
        const propertyMarketOptimizedBytecode = PropertyMarketOptimized.bytecode;
        const mockERC721Bytecode = MockERC721.bytecode;

        // Modular contract sizes
        const storageSize = (PropertyMarketStorage.bytecode.length - 2) / 2;
        const coreSize = (PropertyMarketCore.bytecode.length - 2) / 2;
        const biddingSize = (PropertyMarketBidding.bytecode.length - 2) / 2;
        const adminSize = (PropertyMarketAdmin.bytecode.length - 2) / 2;
        const coordinatorSize = (PropertyMarketCoordinator.bytecode.length - 2) / 2;

        const propertyMarketSize = (propertyMarketBytecode.length - 2) / 2; // Remove 0x and divide by 2
        const propertyMarketOptimizedSize = (propertyMarketOptimizedBytecode.length - 2) / 2;
        const mockERC721Size = (mockERC721Bytecode.length - 2) / 2;
        
        console.log("\n📊 Contract Sizes:");
        console.log("PropertyMarket (Original):", propertyMarketSize, "bytes");
        console.log("PropertyMarketOptimized:", propertyMarketOptimizedSize, "bytes");
        console.log("MockERC721:", mockERC721Size, "bytes");
        console.log("\n📊 Modular Contract Sizes:");
        console.log("PropertyMarketStorage:", storageSize, "bytes");
        console.log("PropertyMarketCore:", coreSize, "bytes");
        console.log("PropertyMarketBidding:", biddingSize, "bytes");
        console.log("PropertyMarketAdmin:", adminSize, "bytes");
        console.log("PropertyMarketCoordinator:", coordinatorSize, "bytes");
        console.log("Total Modular Size:", storageSize + coreSize + biddingSize + adminSize + coordinatorSize, "bytes");

        // Check if contracts are within deployment limit
        const deploymentLimit = 24576; // 24KB
        console.log("\n🚦 Deployment Check:");
        console.log("PropertyMarket size:", propertyMarketSize, "bytes");
        console.log("PropertyMarketOptimized size:", propertyMarketOptimizedSize, "bytes");
        console.log("Deployment limit:", deploymentLimit, "bytes");
        console.log("PropertyMarket within limit:", propertyMarketSize <= deploymentLimit ? "✅ YES" : "❌ NO");
        console.log("PropertyMarketOptimized within limit:", propertyMarketOptimizedSize <= deploymentLimit ? "✅ YES" : "❌ NO");

        const sizeDifference = propertyMarketSize - propertyMarketOptimizedSize;
        const percentageReduction = ((sizeDifference / propertyMarketSize) * 100).toFixed(2);
        console.log("\n📈 Optimization Results:");
        console.log("Size reduction:", sizeDifference, "bytes");
        console.log("Percentage reduction:", percentageReduction + "%");

        if (propertyMarketOptimizedSize > deploymentLimit) {
            console.log("\n⚠️  WARNING: PropertyMarketOptimized still exceeds deployment size limit!");
            console.log("   Contract splitting may be required.");
        } else {
            console.log("\n🎉 PropertyMarketOptimized is within deployment size limit!");
        }

        // Check modular contracts
        console.log("\n🚦 Modular Contracts Deployment Check:");
        const modularContracts = [
            { name: "Storage", size: storageSize },
            { name: "Core", size: coreSize },
            { name: "Bidding", size: biddingSize },
            { name: "Admin", size: adminSize },
            { name: "Coordinator", size: coordinatorSize }
        ];

        let allModularWithinLimit = true;
        modularContracts.forEach(contract => {
            const withinLimit = contract.size <= deploymentLimit;
            console.log(`${contract.name}: ${contract.size} bytes - ${withinLimit ? "✅ OK" : "❌ TOO LARGE"}`);
            if (!withinLimit) allModularWithinLimit = false;
        });

        if (allModularWithinLimit) {
            console.log("\n🎉 All modular contracts are within deployment size limit!");
            console.log("✅ Contract splitting successful!");
        } else {
            console.log("\n⚠️  Some modular contracts still exceed the limit!");
        }
        
        console.log("\n🎉 All contracts compiled successfully!");
        
    } catch (error) {
        console.error("❌ Compilation failed:");
        console.error(error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

module.exports = main;
