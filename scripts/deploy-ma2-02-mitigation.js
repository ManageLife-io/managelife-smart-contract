const { ethers } = require("hardhat");

async function main() {
    console.log("🚀 Deploying MA2-02 Mitigation: Timelock + MultiSig System");
    console.log("=" .repeat(60));
    
    const [deployer, admin, signer1, signer2, signer3, signer4, signer5] = await ethers.getSigners();
    
    console.log("📋 Deployment Configuration:");
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Admin: ${admin.address}`);
    console.log(`Signers: ${signer1.address}, ${signer2.address}, ${signer3.address}, ${signer4.address}, ${signer5.address}`);
    console.log("");
    
    // Step 1: Deploy PropertyMarketTimelock
    console.log("⏰ Step 1: Deploying PropertyMarketTimelock...");
    
    const proposers = [admin.address]; // Admin can propose operations
    const executors = []; // Anyone can execute after delay (open execution)
    const timelockAdmin = admin.address; // Admin manages timelock roles
    
    const TimelockFactory = await ethers.getContractFactory("PropertyMarketTimelock");
    const timelock = await TimelockFactory.deploy(proposers, executors, timelockAdmin);
    await timelock.deployed();
    
    console.log(`✅ PropertyMarketTimelock deployed at: ${timelock.address}`);
    console.log(`   - Min Delay: 48 hours`);
    console.log(`   - Proposers: ${proposers.join(", ")}`);
    console.log(`   - Executors: Open execution`);
    console.log("");
    
    // Step 2: Deploy MultiSigOperator
    console.log("🔐 Step 2: Deploying MultiSigOperator...");
    
    // Assume PropertyMarket is already deployed (replace with actual address)
    const PROPERTY_MARKET_ADDRESS = process.env.PROPERTY_MARKET_ADDRESS || "0x0000000000000000000000000000000000000000";
    
    if (PROPERTY_MARKET_ADDRESS === "0x0000000000000000000000000000000000000000") {
        console.log("⚠️  Warning: PROPERTY_MARKET_ADDRESS not set. Using placeholder.");
        console.log("   Please set PROPERTY_MARKET_ADDRESS environment variable before actual deployment.");
    }
    
    const initialSigners = [
        signer1.address,
        signer2.address,
        signer3.address,
        signer4.address,
        signer5.address
    ];
    
    const MultiSigFactory = await ethers.getContractFactory("MultiSigOperator");
    const multiSig = await MultiSigFactory.deploy(
        timelock.address,
        PROPERTY_MARKET_ADDRESS,
        initialSigners,
        admin.address
    );
    await multiSig.deployed();
    
    console.log(`✅ MultiSigOperator deployed at: ${multiSig.address}`);
    console.log(`   - Required Signatures: 3/5`);
    console.log(`   - Signers: ${initialSigners.join(", ")}`);
    console.log(`   - Admin: ${admin.address}`);
    console.log("");
    
    // Step 3: Grant roles to MultiSig in Timelock
    console.log("🔑 Step 3: Setting up Timelock roles...");
    
    // Grant PROPOSER_ROLE to MultiSig so it can propose operations
    const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
    await timelock.connect(admin).grantRole(PROPOSER_ROLE, multiSig.address);
    console.log(`✅ Granted PROPOSER_ROLE to MultiSig: ${multiSig.address}`);
    
    // Optionally revoke PROPOSER_ROLE from admin for full decentralization
    // await timelock.connect(admin).revokeRole(PROPOSER_ROLE, admin.address);
    // console.log(`✅ Revoked PROPOSER_ROLE from admin: ${admin.address}`);
    
    console.log("");
    
    // Step 4: Display integration instructions
    console.log("🔧 Step 4: PropertyMarket Integration Instructions");
    console.log("=" .repeat(60));
    console.log("To complete the MA2-02 mitigation setup:");
    console.log("");
    console.log("1. Call PropertyMarket.setTimelock() with timelock address:");
    console.log(`   propertyMarket.setTimelock("${timelock.address}")`);
    console.log("");
    console.log("2. Call PropertyMarket.setMultiSigOperator() with multisig address:");
    console.log(`   propertyMarket.setMultiSigOperator("${multiSig.address}")`);
    console.log("");
    console.log("3. Enable timelock requirement:");
    console.log(`   propertyMarket.setTimelockEnabled(true)`);
    console.log("");
    console.log("4. Grant OPERATOR_ROLE to timelock in PropertyMarket:");
    console.log(`   propertyMarket.grantRole(OPERATOR_ROLE, "${timelock.address}")`);
    console.log("");
    console.log("5. Revoke OPERATOR_ROLE from current operators:");
    console.log(`   propertyMarket.revokeRole(OPERATOR_ROLE, currentOperatorAddress)`);
    console.log("");
    
    // Step 5: Generate example operations
    console.log("📝 Step 5: Example Sensitive Operations");
    console.log("=" .repeat(60));
    console.log("");
    console.log("Example 1: Add Payment Token");
    console.log("MultiSig signers should call:");
    console.log(`multiSig.submitTransaction(`);
    console.log(`  "${PROPERTY_MARKET_ADDRESS}",`);
    console.log(`  0,`);
    console.log(`  "0x" + propertyMarket.interface.encodeFunctionData("addAllowedToken", ["0xTokenAddress"]),`);
    console.log(`  "Add USDC as payment token"`);
    console.log(`);`);
    console.log("");
    
    console.log("Example 2: Update Whitelist Status");
    console.log("MultiSig signers should call:");
    console.log(`multiSig.submitTransaction(`);
    console.log(`  "${PROPERTY_MARKET_ADDRESS}",`);
    console.log(`  0,`);
    console.log(`  "0x" + propertyMarket.interface.encodeFunctionData("setWhitelistEnabled", [false]),`);
    console.log(`  "Disable payment token whitelist"`);
    console.log(`);`);
    console.log("");
    
    // Step 6: Security recommendations
    console.log("🛡️  Step 6: Security Recommendations");
    console.log("=" .repeat(60));
    console.log("");
    console.log("1. Signer Key Management:");
    console.log("   - Use hardware wallets for all multisig signers");
    console.log("   - Store private keys in secure, offline environments");
    console.log("   - Implement key rotation procedures");
    console.log("");
    console.log("2. Operational Security:");
    console.log("   - Verify all transaction details before signing");
    console.log("   - Use secure communication channels for coordination");
    console.log("   - Maintain audit logs of all operations");
    console.log("");
    console.log("3. Transparency:");
    console.log("   - Publish timelock and multisig addresses publicly");
    console.log("   - Create a public dashboard for pending operations");
    console.log("   - Announce sensitive operations in advance");
    console.log("");
    
    // Step 7: Contract addresses summary
    console.log("📋 Step 7: Deployment Summary");
    console.log("=" .repeat(60));
    console.log(`PropertyMarketTimelock: ${timelock.address}`);
    console.log(`MultiSigOperator: ${multiSig.address}`);
    console.log(`PropertyMarket: ${PROPERTY_MARKET_ADDRESS}`);
    console.log("");
    console.log("⚠️  IMPORTANT: Save these addresses securely!");
    console.log("⚠️  Update your frontend and documentation with these addresses.");
    console.log("");
    
    // Step 8: Verification commands
    console.log("🔍 Step 8: Verification Commands");
    console.log("=" .repeat(60));
    console.log("To verify contracts on Etherscan:");
    console.log("");
    console.log(`npx hardhat verify --network mainnet ${timelock.address} \\`);
    console.log(`  '[${proposers.map(p => `"${p}"`).join(",")}]' \\`);
    console.log(`  '[]' \\`);
    console.log(`  '${timelockAdmin}'`);
    console.log("");
    console.log(`npx hardhat verify --network mainnet ${multiSig.address} \\`);
    console.log(`  '${timelock.address}' \\`);
    console.log(`  '${PROPERTY_MARKET_ADDRESS}' \\`);
    console.log(`  '[${initialSigners.map(s => `"${s}"`).join(",")}]' \\`);
    console.log(`  '${admin.address}'`);
    console.log("");
    
    console.log("🎉 MA2-02 Mitigation Deployment Complete!");
    console.log("   Centralization risk significantly reduced through:");
    console.log("   ✅ 48-hour timelock for sensitive operations");
    console.log("   ✅ 3/5 multisig requirement for operator functions");
    console.log("   ✅ Transparent operation scheduling and execution");
    console.log("   ✅ Role-based access control with enhanced security");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });
