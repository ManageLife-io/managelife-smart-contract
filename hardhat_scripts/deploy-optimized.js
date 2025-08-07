const { ethers } = require("hardhat");

async function main() {
    console.log("🚀 Starting PropertyMarketOptimized deployment...\n");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);
    console.log("Account balance:", ethers.utils.formatEther(await deployer.getBalance()), "ETH\n");

    // Deploy mock NFT contracts for testing
    console.log("📦 Deploying mock NFT contracts...");
    
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    
    // Deploy NFTI (Property NFT)
    const nftiContract = await MockERC721.deploy("Property NFT", "NFTI");
    await nftiContract.deployed();
    console.log("✅ NFTI Contract deployed to:", nftiContract.address);

    // Deploy PropertyMarketOptimized
    console.log("\n📦 Deploying PropertyMarketOptimized contract...");
    
    const PropertyMarket = await ethers.getContractFactory("PropertyMarketOptimized");
    const propertyMarket = await PropertyMarket.deploy(
        nftiContract.address,    // _nftiAddress
        deployer.address         // _feeCollector
    );
    await propertyMarket.deployed();
    console.log("✅ PropertyMarketOptimized deployed to:", propertyMarket.address);

    // Setup initial configuration
    console.log("\n⚙️ Setting up initial configuration...");
    
    // Mint test NFTs
    console.log("🎨 Minting test NFTs...");
    await nftiContract.mintWithId(deployer.address, 1);
    await nftiContract.mintWithId(deployer.address, 2);
    await nftiContract.mintWithId(deployer.address, 3);
    console.log("✅ Minted NFTs with IDs: 1, 2, 3");

    // Approve PropertyMarket to transfer NFTs
    await nftiContract.setApprovalForAll(propertyMarket.address, true);
    console.log("✅ Approved PropertyMarket to transfer NFTs");

    // Verify deployment
    console.log("\n🔍 Verifying deployment...");
    const nftiAddress = await propertyMarket.nftiContract();
    const feeCollector = await propertyMarket.feeCollector();
    const baseFee = await propertyMarket.baseFee();
    
    console.log("NFTI Contract in PropertyMarket:", nftiAddress);
    console.log("Fee Collector:", feeCollector);
    console.log("Base Fee:", baseFee.toString(), "basis points");
    console.log("Match NFTI:", nftiAddress === nftiContract.address);

    // Save deployment info
    const deploymentInfo = {
        network: await ethers.provider.getNetwork(),
        deployer: deployer.address,
        contracts: {
            PropertyMarketOptimized: propertyMarket.address,
            NFTI: nftiContract.address
        },
        configuration: {
            feeCollector: feeCollector,
            baseFee: baseFee.toString()
        },
        deploymentTime: new Date().toISOString()
    };

    console.log("\n📋 Deployment Summary:");
    console.log("=".repeat(60));
    console.log("Network:", deploymentInfo.network.name, `(Chain ID: ${deploymentInfo.network.chainId})`);
    console.log("Deployer:", deploymentInfo.deployer);
    console.log("PropertyMarketOptimized:", deploymentInfo.contracts.PropertyMarketOptimized);
    console.log("NFTI Contract:", deploymentInfo.contracts.NFTI);
    console.log("Fee Collector:", deploymentInfo.configuration.feeCollector);
    console.log("Base Fee:", deploymentInfo.configuration.baseFee, "basis points");
    console.log("Deployment Time:", deploymentInfo.deploymentTime);
    console.log("=".repeat(60));

    // Save to file
    const fs = require('fs');
    fs.writeFileSync(
        'deployment-optimized.json', 
        JSON.stringify(deploymentInfo, null, 2)
    );
    console.log("💾 Deployment info saved to deployment-optimized.json");

    return {
        propertyMarket,
        nftiContract,
        deploymentInfo
    };
}

// Execute deployment
if (require.main === module) {
    main()
        .then(() => {
            console.log("\n🎉 Deployment completed successfully!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Deployment failed:");
            console.error(error);
            process.exit(1);
        });
}

module.exports = main;
