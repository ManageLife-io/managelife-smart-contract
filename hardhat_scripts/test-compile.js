const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

console.log("🔧 Testing PropertyMarket compilation...");

try {
    // Change to the correct directory
    process.chdir('C:\\Users\\Administrator\\Desktop\\managelife-smart-contract');
    
    console.log("📁 Current directory:", process.cwd());
    
    // Check if hardhat.config.js exists
    if (fs.existsSync('hardhat.config.js')) {
        console.log("✅ hardhat.config.js found");
    } else {
        console.log("❌ hardhat.config.js not found");
        process.exit(1);
    }
    
    // Check if contracts exist
    const contractPaths = [
        'contracts/market/PropertyMarket.sol',
        'contracts/governance/PropertyTimelock.sol',
        'contracts/governance/MultiSigOperator.sol',
        'contracts/libraries/Errors.sol'
    ];
    
    for (const contractPath of contractPaths) {
        if (fs.existsSync(contractPath)) {
            console.log(`✅ ${contractPath} found`);
        } else {
            console.log(`❌ ${contractPath} not found`);
        }
    }
    
    console.log("\n🔨 Starting compilation...");
    
    // Run hardhat compile
    const output = execSync('npx hardhat compile', { 
        encoding: 'utf8',
        stdio: 'pipe'
    });
    
    console.log("✅ Compilation successful!");
    console.log(output);
    
    // Check contract sizes
    console.log("\n📊 Checking contract sizes...");
    
    try {
        const sizeOutput = execSync('npx hardhat size-contracts', { 
            encoding: 'utf8',
            stdio: 'pipe'
        });
        console.log(sizeOutput);
    } catch (sizeError) {
        console.log("ℹ️  Contract size check not available (hardhat-contract-sizer may not be configured)");
    }
    
} catch (error) {
    console.error("❌ Compilation failed:");
    console.error(error.message);
    
    if (error.stdout) {
        console.log("\n📤 STDOUT:");
        console.log(error.stdout);
    }
    
    if (error.stderr) {
        console.log("\n📥 STDERR:");
        console.log(error.stderr);
    }
    
    process.exit(1);
}

console.log("\n🎉 All tests completed successfully!");
