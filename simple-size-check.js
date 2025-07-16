const fs = require('fs');

console.log('🔍 Simple Contract Size Check...\n');

try {
    // Read PropertyMarket artifact
    const propertyMarketArtifact = JSON.parse(
        fs.readFileSync('browser/contracts/artifacts/contracts/market/PropertyMarket.sol/PropertyMarket.json', 'utf8')
    );
    
    const bytecode = propertyMarketArtifact.bytecode;
    console.log('PropertyMarket Contract Analysis:');
    console.log('================================');
    
    if (bytecode && bytecode.length > 0) {
        // Remove 0x prefix
        const cleanBytecode = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
        
        // Calculate size
        const sizeInBytes = cleanBytecode.length / 2;
        const sizeInKiB = sizeInBytes / 1024;
        
        console.log(`Bytecode length: ${bytecode.length} characters`);
        console.log(`Contract size: ${sizeInBytes} bytes`);
        console.log(`Contract size: ${sizeInKiB.toFixed(3)} KiB`);
        console.log(`Deployment limit: 24,576 bytes (24.000 KiB)`);
        
        if (sizeInKiB > 24.000) {
            const excess = sizeInBytes - 24576;
            const excessKiB = excess / 1024;
            console.log(`❌ STATUS: EXCEEDS LIMIT`);
            console.log(`   Excess: ${excess} bytes (${excessKiB.toFixed(3)} KiB)`);
            console.log(`   Reduction needed: ${((excess / sizeInBytes) * 100).toFixed(1)}%`);
        } else {
            const remaining = 24576 - sizeInBytes;
            const remainingKiB = remaining / 1024;
            console.log(`✅ STATUS: WITHIN LIMIT`);
            console.log(`   Remaining: ${remaining} bytes (${remainingKiB.toFixed(3)} KiB)`);
            console.log(`   Usage: ${((sizeInBytes / 24576) * 100).toFixed(1)}%`);
        }
    } else {
        console.log('❌ No bytecode found in artifact');
    }
    
    // Also check other main contracts
    console.log('\n' + '='.repeat(50));
    console.log('Other Contracts:');
    console.log('='.repeat(50));
    
    const otherContracts = [
        { path: 'browser/contracts/artifacts/contracts/tokens/LifeToken.sol/LifeToken.json', name: 'LifeToken' },
        { path: 'browser/contracts/artifacts/contracts/nft/NFTm.sol/NFTm.json', name: 'NFTm' }
    ];
    
    for (const contract of otherContracts) {
        try {
            const artifact = JSON.parse(fs.readFileSync(contract.path, 'utf8'));
            const bytecode = artifact.bytecode;
            
            if (bytecode && bytecode.length > 0) {
                const cleanBytecode = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
                const sizeInBytes = cleanBytecode.length / 2;
                const sizeInKiB = sizeInBytes / 1024;
                const status = sizeInKiB > 24.000 ? '❌ OVER' : '✅ OK';
                
                console.log(`${contract.name}: ${sizeInBytes} bytes (${sizeInKiB.toFixed(3)} KiB) ${status}`);
            }
        } catch (error) {
            console.log(`${contract.name}: Error reading artifact`);
        }
    }
    
} catch (error) {
    console.error('❌ Error reading PropertyMarket artifact:', error.message);
}

console.log('\n' + '='.repeat(50));
console.log('Size Check Complete');
console.log('='.repeat(50));
