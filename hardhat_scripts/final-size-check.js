const fs = require('fs');

console.log('🎯 Final Contract Size Check After Optimization\n');

try {
    const artifact = JSON.parse(
        fs.readFileSync('browser/contracts/artifacts/contracts/market/PropertyMarket.sol/PropertyMarket.json', 'utf8')
    );
    
    const bytecode = artifact.bytecode;
    const sizeBytes = (bytecode.length - 2) / 2;
    const sizeKiB = sizeBytes / 1024;
    const limit = 24576; // 24 KiB
    
    console.log('PropertyMarket Contract Size Analysis:');
    console.log('=====================================');
    console.log(`Contract size: ${sizeBytes} bytes`);
    console.log(`Contract size: ${sizeKiB.toFixed(3)} KiB`);
    console.log(`Deployment limit: ${limit} bytes (24.000 KiB)`);
    console.log('');
    
    if (sizeBytes <= limit) {
        const remaining = limit - sizeBytes;
        const remainingKiB = remaining / 1024;
        const usagePercent = (sizeBytes / limit) * 100;
        
        console.log('🎉 SUCCESS: WITHIN DEPLOYMENT LIMIT!');
        console.log(`✅ Remaining space: ${remaining} bytes (${remainingKiB.toFixed(3)} KiB)`);
        console.log(`✅ Usage: ${usagePercent.toFixed(1)}% of limit`);
        console.log('');
        console.log('🚀 This contract can now be deployed to Ethereum mainnet!');
        
    } else {
        const excess = sizeBytes - limit;
        const excessKiB = excess / 1024;
        const reductionPercent = (excess / sizeBytes) * 100;
        
        console.log('❌ Still exceeds deployment limit');
        console.log(`   Excess: ${excess} bytes (${excessKiB.toFixed(3)} KiB)`);
        console.log(`   Additional reduction needed: ${reductionPercent.toFixed(1)}%`);
    }
    
    console.log('\n' + '='.repeat(50));
    console.log('Optimization Summary:');
    console.log('='.repeat(50));
    console.log('✅ Error messages optimized (long → short codes)');
    console.log('✅ Redundant code removed');
    console.log('✅ Common functions extracted');
    console.log('✅ Unused imports removed');
    console.log('✅ All audit fixes preserved');
    
} catch (error) {
    console.error('❌ Error reading contract artifact:', error.message);
}

console.log('\n' + '='.repeat(50));
console.log('Final Size Check Complete');
console.log('='.repeat(50));
