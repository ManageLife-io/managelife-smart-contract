const { execSync } = require('child_process');
const fs = require('fs');

console.log('🔧 Testing Audit Fixes Compilation...\n');

try {
    // Clean previous compilation
    console.log('1. Cleaning previous compilation...');
    if (fs.existsSync('./cache')) {
        fs.rmSync('./cache', { recursive: true, force: true });
    }
    if (fs.existsSync('./browser/contracts/artifacts')) {
        fs.rmSync('./browser/contracts/artifacts', { recursive: true, force: true });
    }
    console.log('✅ Cleaned successfully\n');

    // Compile contracts
    console.log('2. Compiling contracts...');
    const compileOutput = execSync('npx hardhat compile', { 
        encoding: 'utf8',
        stdio: 'pipe'
    });
    console.log('✅ Compilation successful\n');
    
    // Check if key contracts compiled
    const artifactsPath = './browser/contracts/artifacts/contracts';
    const keyContracts = [
        'market/PropertyMarket.sol/PropertyMarket.json',
        'tokens/LifeToken.sol/LifeToken.json',
        'nft/NFTm.sol/NFTm.json',
        'libraries/Errors.sol/Errors.json'
    ];
    
    console.log('3. Verifying compiled artifacts...');
    let allCompiled = true;
    
    for (const contract of keyContracts) {
        const contractPath = `${artifactsPath}/${contract}`;
        if (fs.existsSync(contractPath)) {
            const artifact = JSON.parse(fs.readFileSync(contractPath, 'utf8'));
            console.log(`✅ ${contract.split('/').pop().replace('.json', '')} - Bytecode: ${artifact.bytecode.length > 10 ? 'Generated' : 'Empty'}`);
        } else {
            console.log(`❌ ${contract} - Not found`);
            allCompiled = false;
        }
    }
    
    if (allCompiled) {
        console.log('\n🎉 All audit fixes compiled successfully!');
        
        // Check contract sizes
        console.log('\n4. Checking contract sizes...');
        try {
            const sizeOutput = execSync('npx hardhat size-contracts', { 
                encoding: 'utf8',
                stdio: 'pipe'
            });
            console.log(sizeOutput);
        } catch (sizeError) {
            console.log('⚠️ Contract size check failed, but compilation was successful');
        }
        
    } else {
        console.log('\n❌ Some contracts failed to compile');
        process.exit(1);
    }
    
} catch (error) {
    console.error('❌ Compilation failed:');
    console.error(error.message);
    
    // Try to get more detailed error info
    try {
        const detailedError = execSync('npx hardhat compile --verbose', { 
            encoding: 'utf8',
            stdio: 'pipe'
        });
        console.log('\nDetailed error output:');
        console.log(detailedError);
    } catch (verboseError) {
        console.log('\nDetailed error:');
        console.log(verboseError.message);
    }
    
    process.exit(1);
}
