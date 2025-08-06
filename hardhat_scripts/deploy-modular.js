const { ethers } = require("hardhat");

async function main() {
    console.log("🚀 Starting Modular PropertyMarket deployment...\n");

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
    
    // Deploy NFTM (Membership NFT)
    const nftmContract = await MockERC721.deploy("Membership NFT", "NFTM");
    await nftmContract.deployed();
    console.log("✅ NFTM Contract deployed to:", nftmContract.address);

    // Step 1: Deploy Storage Contract
    console.log("\n📦 Deploying PropertyMarketStorage...");
    
    const PropertyMarketStorage = await ethers.getContractFactory("PropertyMarketStorage");
    const storageContract = await PropertyMarketStorage.deploy(
        nftiContract.address,    // _nftiAddress
        nftmContract.address,    // _nftmAddress
        deployer.address,        // initialAdmin
        deployer.address,        // feeCollector
        deployer.address         // rewardsVault
    );
    await storageContract.deployed();
    console.log("✅ PropertyMarketStorage deployed to:", storageContract.address);

    // Step 2: Deploy Core Module
    console.log("\n📦 Deploying PropertyMarketCore...");
    
    const PropertyMarketCore = await ethers.getContractFactory("PropertyMarketCore");
    const coreContract = await PropertyMarketCore.deploy(storageContract.address);
    await coreContract.deployed();
    console.log("✅ PropertyMarketCore deployed to:", coreContract.address);

    // Step 3: Deploy Bidding Module
    console.log("\n📦 Deploying PropertyMarketBidding...");
    
    const PropertyMarketBidding = await ethers.getContractFactory("PropertyMarketBidding");
    const biddingContract = await PropertyMarketBidding.deploy(storageContract.address);
    await biddingContract.deployed();
    console.log("✅ PropertyMarketBidding deployed to:", biddingContract.address);

    // Step 4: Deploy Admin Module
    console.log("\n📦 Deploying PropertyMarketAdmin...");
    
    const PropertyMarketAdmin = await ethers.getContractFactory("PropertyMarketAdmin");
    const adminContract = await PropertyMarketAdmin.deploy(storageContract.address);
    await adminContract.deployed();
    console.log("✅ PropertyMarketAdmin deployed to:", adminContract.address);

    // Step 5: Deploy Coordinator
    console.log("\n📦 Deploying PropertyMarketCoordinator...");
    
    const PropertyMarketCoordinator = await ethers.getContractFactory("PropertyMarketCoordinator");
    const coordinatorContract = await PropertyMarketCoordinator.deploy(
        storageContract.address,
        coreContract.address,
        biddingContract.address,
        adminContract.address
    );
    await coordinatorContract.deployed();
    console.log("✅ PropertyMarketCoordinator deployed to:", coordinatorContract.address);

    // Step 6: Configure Storage Contract with Module Addresses
    console.log("\n⚙️ Configuring module addresses in storage contract...");
    
    const tx = await storageContract.setModules(
        coreContract.address,
        biddingContract.address,
        adminContract.address
    );
    await tx.wait();
    console.log("✅ Module addresses configured");

    // Step 7: Setup initial configuration
    console.log("\n⚙️ Setting up initial configuration...");
    
    // Mint test NFTs
    console.log("🎨 Minting test NFTs...");
    await nftiContract.mintWithId(deployer.address, 1);
    await nftiContract.mintWithId(deployer.address, 2);
    await nftiContract.mintWithId(deployer.address, 3);
    console.log("✅ Minted NFTs with IDs: 1, 2, 3");

    // Approve Coordinator to transfer NFTs
    await nftiContract.setApprovalForAll(coordinatorContract.address, true);
    console.log("✅ Approved Coordinator to transfer NFTs");

    // Grant KYC verification to deployer
    await coordinatorContract.grantKYCVerification(deployer.address);
    console.log("✅ Granted KYC verification to deployer");

    // Verify deployment
    console.log("\n🔍 Verifying deployment...");
    const [nftiAddr, nftmAddr] = await coordinatorContract.getNFTContracts();
    const [storageAddr, coreAddr, biddingAddr, adminAddr] = await coordinatorContract.getModuleAddresses();
    
    console.log("NFTI Contract:", nftiAddr);
    console.log("NFTM Contract:", nftmAddr);
    console.log("Storage Module:", storageAddr);
    console.log("Core Module:", coreAddr);
    console.log("Bidding Module:", biddingAddr);
    console.log("Admin Module:", adminAddr);
    
    console.log("Match NFTI:", nftiAddr === nftiContract.address);
    console.log("Match NFTM:", nftmAddr === nftmContract.address);

    // Save deployment info
    const deploymentInfo = {
        network: await ethers.provider.getNetwork(),
        deployer: deployer.address,
        contracts: {
            PropertyMarketCoordinator: coordinatorContract.address,
            PropertyMarketStorage: storageContract.address,
            PropertyMarketCore: coreContract.address,
            PropertyMarketBidding: biddingContract.address,
            PropertyMarketAdmin: adminContract.address,
            NFTI: nftiContract.address,
            NFTM: nftmContract.address
        },
        deploymentTime: new Date().toISOString()
    };

    console.log("\n📋 Deployment Summary:");
    console.log("=".repeat(70));
    console.log("Network:", deploymentInfo.network.name, `(Chain ID: ${deploymentInfo.network.chainId})`);
    console.log("Deployer:", deploymentInfo.deployer);
    console.log("Coordinator:", deploymentInfo.contracts.PropertyMarketCoordinator);
    console.log("Storage:", deploymentInfo.contracts.PropertyMarketStorage);
    console.log("Core:", deploymentInfo.contracts.PropertyMarketCore);
    console.log("Bidding:", deploymentInfo.contracts.PropertyMarketBidding);
    console.log("Admin:", deploymentInfo.contracts.PropertyMarketAdmin);
    console.log("NFTI:", deploymentInfo.contracts.NFTI);
    console.log("NFTM:", deploymentInfo.contracts.NFTM);
    console.log("Deployment Time:", deploymentInfo.deploymentTime);
    console.log("=".repeat(70));

    // Save to file
    const fs = require('fs');
    fs.writeFileSync(
        'deployment-modular.json', 
        JSON.stringify(deploymentInfo, null, 2)
    );
    console.log("💾 Deployment info saved to deployment-modular.json");

    return {
        coordinatorContract,
        storageContract,
        coreContract,
        biddingContract,
        adminContract,
        nftiContract,
        nftmContract,
        deploymentInfo
    };
}

// Execute deployment
if (require.main === module) {
    main()
        .then(() => {
            console.log("\n🎉 Modular deployment completed successfully!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Deployment failed:");
            console.error(error);
            process.exit(1);
        });
}

module.exports = main;
