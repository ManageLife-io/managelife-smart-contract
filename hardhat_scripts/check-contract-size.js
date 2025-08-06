const fs = require('fs');

console.log('🔍 Checking Contract Sizes...\n');

// Function to calculate contract size from bytecode
function getContractSize(artifactPath, contractName) {
    try {
        const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
        const bytecode = artifact.bytecode;
        
        // Remove 0x prefix and calculate size
        const bytecodeWithoutPrefix = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
        const sizeInBytes = bytecodeWithoutPrefix.length / 2;
        const sizeInKiB = sizeInBytes / 1024;
        
        return {
            name: contractName,
            sizeInBytes: sizeInBytes,
            sizeInKiB: sizeInKiB.toFixed(3),
            bytecodeLength: bytecode.length,
            isOverLimit: sizeInKiB > 24.576 // 24 KiB = 24.576 KB
        };
    } catch (error) {
        return {
            name: contractName,
            error: error.message
        };
    }
}

// Check main contracts
const contracts = [
    {
        path: 'browser/contracts/artifacts/contracts/market/PropertyMarket.sol/PropertyMarket.json',
        name: 'PropertyMarket'
    },
    {
        path: 'browser/contracts/artifacts/contracts/tokens/LifeToken.sol/LifeToken.json',
        name: 'LifeToken'
    },
    {
        path: 'browser/contracts/artifacts/contracts/nft/NFTm.sol/NFTm.json',
        name: 'NFTm'
    },
    {
        path: 'browser/contracts/artifacts/contracts/nft/NFTi.sol/NFTi.json',
        name: 'NFTi'
    },
    {
        path: 'browser/contracts/artifacts/contracts/governance/AdminControl.sol/AdminControl.json',
        name: 'AdminControl'
    }
];

console.log('Contract Size Analysis:');
console.log('='.repeat(80));
console.log('Contract Name'.padEnd(20) + 'Size (bytes)'.padEnd(15) + 'Size (KiB)'.padEnd(15) + 'Status');
console.log('='.repeat(80));

let totalContracts = 0;
let oversizedContracts = 0;

for (const contract of contracts) {
    const result = getContractSize(contract.path, contract.name);
    
    if (result.error) {
        console.log(`${result.name.padEnd(20)}ERROR: ${result.error}`);
        continue;
    }
    
    totalContracts++;
    
    const status = result.isOverLimit ? '❌ OVER LIMIT' : '✅ OK';
    if (result.isOverLimit) {
        oversizedContracts++;
    }
    
    console.log(
        `${result.name.padEnd(20)}${result.sizeInBytes.toString().padEnd(15)}${result.sizeInKiB.padEnd(15)}${status}`
    );
}

console.log('='.repeat(80));
console.log(`\nSummary:`);
console.log(`Total contracts checked: ${totalContracts}`);
console.log(`Contracts over 24 KiB limit: ${oversizedContracts}`);

if (oversizedContracts > 0) {
    console.log('\n⚠️  WARNING: Some contracts exceed the 24 KiB deployment limit!');
    console.log('   This will prevent deployment to Ethereum mainnet.');
    console.log('   Consider optimization strategies:');
    console.log('   1. Split large contracts into smaller modules');
    console.log('   2. Remove unused functions or variables');
    console.log('   3. Use libraries for common functionality');
    console.log('   4. Optimize storage layout');
    console.log('   5. Remove redundant code');
} else {
    console.log('\n✅ All contracts are within the 24 KiB deployment limit!');
}

// Detailed analysis for PropertyMarket if it exists
const propertyMarketPath = 'browser/contracts/artifacts/contracts/market/PropertyMarket.sol/PropertyMarket.json';
if (fs.existsSync(propertyMarketPath)) {
    console.log('\n' + '='.repeat(50));
    console.log('PropertyMarket Detailed Analysis:');
    console.log('='.repeat(50));
    
    const pmResult = getContractSize(propertyMarketPath, 'PropertyMarket');
    if (!pmResult.error) {
        console.log(`Bytecode length: ${pmResult.bytecodeLength} characters`);
        console.log(`Contract size: ${pmResult.sizeInBytes} bytes (${pmResult.sizeInKiB} KiB)`);
        console.log(`Limit: 24,576 bytes (24.000 KiB)`);
        
        if (pmResult.isOverLimit) {
            const excess = pmResult.sizeInBytes - 24576;
            const excessKiB = (excess / 1024).toFixed(3);
            console.log(`❌ Exceeds limit by: ${excess} bytes (${excessKiB} KiB)`);
            console.log(`   Reduction needed: ${((excess / pmResult.sizeInBytes) * 100).toFixed(1)}%`);
        } else {
            const remaining = 24576 - pmResult.sizeInBytes;
            const remainingKiB = (remaining / 1024).toFixed(3);
            console.log(`✅ Within limit. Remaining space: ${remaining} bytes (${remainingKiB} KiB)`);
        }
    }
}

console.log('\n' + '='.repeat(50));
console.log('Contract Size Check Complete');
console.log('='.repeat(50));
