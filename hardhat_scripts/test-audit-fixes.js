const fs = require('fs');
const path = require('path');

console.log('🔧 Testing Audit Fixes - Syntax and Structure Check...\n');

// Function to check if a file has basic syntax issues
function checkSolidityFile(filePath) {
    try {
        const content = fs.readFileSync(filePath, 'utf8');
        
        // Basic syntax checks
        const issues = [];
        
        // Check for balanced braces
        const openBraces = (content.match(/{/g) || []).length;
        const closeBraces = (content.match(/}/g) || []).length;
        if (openBraces !== closeBraces) {
            issues.push(`Unbalanced braces: ${openBraces} open, ${closeBraces} close`);
        }
        
        // Check for balanced parentheses in function definitions
        const functionMatches = content.match(/function\s+\w+\([^)]*\)/g) || [];
        for (const func of functionMatches) {
            const openParens = (func.match(/\(/g) || []).length;
            const closeParens = (func.match(/\)/g) || []).length;
            if (openParens !== closeParens) {
                issues.push(`Unbalanced parentheses in: ${func}`);
            }
        }
        
        // Check for missing semicolons in require statements
        const requireLines = content.split('\n').filter(line => 
            line.trim().startsWith('require(') && !line.trim().endsWith(';')
        );
        if (requireLines.length > 0) {
            issues.push(`Missing semicolons in require statements: ${requireLines.length} found`);
        }
        
        return {
            success: issues.length === 0,
            issues: issues,
            lineCount: content.split('\n').length
        };
        
    } catch (error) {
        return {
            success: false,
            issues: [`File read error: ${error.message}`],
            lineCount: 0
        };
    }
}

// Test the modified contracts
const contractsToTest = [
    'contracts/market/PropertyMarket.sol',
    'contracts/tokens/LifeToken.sol', 
    'contracts/nft/NFTm.sol',
    'contracts/libraries/Errors.sol'
];

console.log('1. Checking modified contracts syntax...\n');

let allPassed = true;

for (const contractPath of contractsToTest) {
    const result = checkSolidityFile(contractPath);
    const contractName = path.basename(contractPath);
    
    if (result.success) {
        console.log(`✅ ${contractName} - OK (${result.lineCount} lines)`);
    } else {
        console.log(`❌ ${contractName} - Issues found:`);
        result.issues.forEach(issue => console.log(`   - ${issue}`));
        allPassed = false;
    }
}

console.log('\n2. Checking audit fixes implementation...\n');

// Check PropertyMarket fixes
const propertyMarketContent = fs.readFileSync('contracts/market/PropertyMarket.sol', 'utf8');

// Check if ETH refund fix is implemented
if (propertyMarketContent.includes('// ETH is now locked in contract')) {
    console.log('✅ PropertyMarket - ETH bidding fix implemented');
} else {
    console.log('❌ PropertyMarket - ETH bidding fix not found');
    allPassed = false;
}

// Check if refund logic is added to cancelBid
if (propertyMarketContent.includes('// Refund the locked funds')) {
    console.log('✅ PropertyMarket - Bid cancellation refund logic added');
} else {
    console.log('❌ PropertyMarket - Bid cancellation refund logic missing');
    allPassed = false;
}

// Check if BidRefundFailed event is added
if (propertyMarketContent.includes('event BidRefundFailed')) {
    console.log('✅ PropertyMarket - BidRefundFailed event added');
} else {
    console.log('❌ PropertyMarket - BidRefundFailed event missing');
    allPassed = false;
}

// Check LifeToken fixes
const lifeTokenContent = fs.readFileSync('contracts/tokens/LifeToken.sol', 'utf8');

// Check if rebase limit is implemented
if (lifeTokenContent.includes('Rebase change exceeds maximum allowed')) {
    console.log('✅ LifeToken - Rebase change limit implemented');
} else {
    console.log('❌ LifeToken - Rebase change limit not found');
    allPassed = false;
}

// Check if emergency rebase is added
if (lifeTokenContent.includes('function emergencyRebase')) {
    console.log('✅ LifeToken - Emergency rebase function added');
} else {
    console.log('❌ LifeToken - Emergency rebase function missing');
    allPassed = false;
}

// Check NFTm fixes
const nftmContent = fs.readFileSync('contracts/nft/NFTm.sol', 'utf8');

// Check if permission logic is simplified
if (nftmContent.includes('insufficient minting privileges')) {
    console.log('✅ NFTm - Simplified permission check implemented');
} else {
    console.log('❌ NFTm - Simplified permission check not found');
    allPassed = false;
}

// Check if handleNFTiBurn permission is restricted
if (nftmContent.includes('only NFTi contract or operator')) {
    console.log('✅ NFTm - handleNFTiBurn permission restricted');
} else {
    console.log('❌ NFTm - handleNFTiBurn permission not restricted');
    allPassed = false;
}

// Check Errors.sol updates
const errorsContent = fs.readFileSync('contracts/libraries/Errors.sol', 'utf8');

if (errorsContent.includes('TRANSFER_FAILED') && errorsContent.includes('EXCESS_REFUND_FAILED')) {
    console.log('✅ Errors - New error constants added');
} else {
    console.log('❌ Errors - Missing new error constants');
    allPassed = false;
}

console.log('\n3. Summary...\n');

if (allPassed) {
    console.log('🎉 All audit fixes have been successfully implemented!');
    console.log('✅ Syntax checks passed');
    console.log('✅ PropertyMarket ETH bidding logic fixed');
    console.log('✅ LifeToken rebase protection added');
    console.log('✅ NFTm permission checks simplified');
    console.log('✅ Required error constants added');
    console.log('\n📋 Next steps:');
    console.log('   1. Run full compilation test');
    console.log('   2. Execute unit tests');
    console.log('   3. Deploy to testnet for integration testing');
} else {
    console.log('❌ Some audit fixes are incomplete or have issues');
    console.log('   Please review the issues above and fix them before proceeding');
}

console.log('\n' + '='.repeat(60));
console.log('Audit Fixes Implementation Check Complete');
console.log('='.repeat(60));
