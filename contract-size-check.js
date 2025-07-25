const fs = require('fs');

console.log('🔍 Contract Size Check Report\n');

try {
    // Read PropertyMarket artifact
    const propertyMarketPath = 'browser/contracts/artifacts/contracts/market/PropertyMarket.sol/PropertyMarket.json';
    const propertyMarketArtifact = JSON.parse(fs.readFileSync(propertyMarketPath, 'utf8'));
    
    const bytecode = propertyMarketArtifact.bytecode;
    
    if (bytecode && bytecode.length > 0) {
        // Calculate size
        const sizeBytes = (bytecode.length - 2) / 2; // Remove 0x prefix and convert hex to bytes
        const sizeKiB = sizeBytes / 1024;
        const deploymentLimit = 24576; // 24 KiB in bytes
        
        console.log('PropertyMarket Contract Analysis:');
        console.log('================================');
        console.log(`Bytecode length: ${bytecode.length} characters`);
        console.log(`Contract size: ${sizeBytes} bytes`);
        console.log(`Contract size: ${sizeKiB.toFixed(3)} KiB`);
        console.log(`Deployment limit: ${deploymentLimit} bytes (24.000 KiB)`);
        console.log('');
        
        if (sizeBytes > deploymentLimit) {
            const excess = sizeBytes - deploymentLimit;
            const excessKiB = excess / 1024;
            const reductionPercent = (excess / sizeBytes) * 100;
            
            console.log('❌ STATUS: EXCEEDS DEPLOYMENT LIMIT');
            console.log(`   Excess: ${excess} bytes (${excessKiB.toFixed(3)} KiB)`);
            console.log(`   Reduction needed: ${reductionPercent.toFixed(1)}%`);
            console.log('');
            console.log('⚠️  WARNING: This contract cannot be deployed to Ethereum mainnet!');
            console.log('   The contract size exceeds the 24 KiB limit imposed by EIP-170.');
            console.log('');
            console.log('🔧 Optimization suggestions:');
            console.log('   1. Split large functions into smaller ones');
            console.log('   2. Move common logic to libraries');
            console.log('   3. Remove unused functions or variables');
            console.log('   4. Optimize storage layout');
            console.log('   5. Use external libraries for complex operations');
            
        } else {
            const remaining = deploymentLimit - sizeBytes;
            const remainingKiB = remaining / 1024;
            const usagePercent = (sizeBytes / deploymentLimit) * 100;
            
            console.log('✅ STATUS: WITHIN DEPLOYMENT LIMIT');
            console.log(`   Remaining space: ${remaining} bytes (${remainingKiB.toFixed(3)} KiB)`);
            console.log(`   Usage: ${usagePercent.toFixed(1)}% of limit`);
            console.log('');
            console.log('🎉 This contract can be deployed to Ethereum mainnet!');
        }
        
        // Check other contracts for comparison
        console.log('\n' + '='.repeat(50));
        console.log('Other Contracts Size Check:');
        console.log('='.repeat(50));
        
        const otherContracts = [
            { path: 'browser/contracts/artifacts/contracts/tokens/LifeToken.sol/LifeToken.json', name: 'LifeToken' },
            { path: 'browser/contracts/artifacts/contracts/nft/NFTm.sol/NFTm.json', name: 'NFTm' }
        ];
        
        for (const contract of otherContracts) {
            try {
                const artifact = JSON.parse(fs.readFileSync(contract.path, 'utf8'));
                const contractBytecode = artifact.bytecode;
                
                if (contractBytecode && contractBytecode.length > 0) {
                    const contractSizeBytes = (contractBytecode.length - 2) / 2;
                    const contractSizeKiB = contractSizeBytes / 1024;
                    const status = contractSizeBytes > deploymentLimit ? '❌ OVER LIMIT' : '✅ OK';
                    
                    console.log(`${contract.name.padEnd(15)}: ${contractSizeBytes.toString().padEnd(8)} bytes (${contractSizeKiB.toFixed(3).padEnd(7)} KiB) ${status}`);
                } else {
                    console.log(`${contract.name.padEnd(15)}: No bytecode found`);
                }
            } catch (error) {
                console.log(`${contract.name.padEnd(15)}: Error reading artifact`);
            }
        }
        
    } else {
        console.log('❌ No bytecode found in PropertyMarket artifact');
    }
    
} catch (error) {
    console.error('❌ Error reading PropertyMarket artifact:', error.message);
}

console.log('\n' + '='.repeat(50));
console.log('Contract Size Check Complete');
console.log('='.repeat(50));
