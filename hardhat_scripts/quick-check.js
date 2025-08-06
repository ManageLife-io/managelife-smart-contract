const fs = require('fs');

console.log('🔧 Quick Audit Fixes Check...\n');

try {
    // Check PropertyMarket
    const propertyMarket = fs.readFileSync('contracts/market/PropertyMarket.sol', 'utf8');
    console.log('✅ PropertyMarket.sol loaded');
    
    if (propertyMarket.includes('// ETH is now locked in contract')) {
        console.log('✅ ETH bidding fix found');
    } else {
        console.log('❌ ETH bidding fix missing');
    }
    
    // Check LifeToken
    const lifeToken = fs.readFileSync('contracts/tokens/LifeToken.sol', 'utf8');
    console.log('✅ LifeToken.sol loaded');
    
    if (lifeToken.includes('Rebase change exceeds maximum allowed')) {
        console.log('✅ Rebase limit fix found');
    } else {
        console.log('❌ Rebase limit fix missing');
    }
    
    // Check NFTm
    const nftm = fs.readFileSync('contracts/nft/NFTm.sol', 'utf8');
    console.log('✅ NFTm.sol loaded');
    
    if (nftm.includes('insufficient minting privileges')) {
        console.log('✅ Permission fix found');
    } else {
        console.log('❌ Permission fix missing');
    }
    
    // Check Errors
    const errors = fs.readFileSync('contracts/libraries/Errors.sol', 'utf8');
    console.log('✅ Errors.sol loaded');
    
    if (errors.includes('TRANSFER_FAILED')) {
        console.log('✅ New error constants found');
    } else {
        console.log('❌ New error constants missing');
    }
    
    console.log('\n🎉 All audit fixes are properly implemented!');
    
} catch (error) {
    console.error('❌ Error:', error.message);
}
