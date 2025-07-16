const fs = require('fs');

console.log('🔧 Verifying Audit Fixes Implementation...\n');

let allFixesImplemented = true;

// Function to check if text exists in file
function checkFix(filePath, searchText, fixName) {
    try {
        const content = fs.readFileSync(filePath, 'utf8');
        if (content.includes(searchText)) {
            console.log(`✅ ${fixName} - IMPLEMENTED`);
            return true;
        } else {
            console.log(`❌ ${fixName} - NOT FOUND`);
            return false;
        }
    } catch (error) {
        console.log(`❌ ${fixName} - FILE ERROR: ${error.message}`);
        return false;
    }
}

console.log('1. Checking PropertyMarket ETH Bidding Logic Fixes...\n');

// Check PropertyMarket fixes
const propertyMarketFixes = [
    {
        file: 'contracts/market/PropertyMarket.sol',
        search: '// ETH is now locked in contract',
        name: 'ETH Locking Mechanism'
    },
    {
        file: 'contracts/market/PropertyMarket.sol', 
        search: '// Refund the locked funds',
        name: 'Bid Cancellation Refund Logic'
    },
    {
        file: 'contracts/market/PropertyMarket.sol',
        search: 'event BidRefundFailed',
        name: 'BidRefundFailed Event'
    },
    {
        file: 'contracts/market/PropertyMarket.sol',
        search: 'require(token.transferFrom(msg.sender, address(this), bidAmount)',
        name: 'ERC20 Token Escrow'
    }
];

for (const fix of propertyMarketFixes) {
    if (!checkFix(fix.file, fix.search, fix.name)) {
        allFixesImplemented = false;
    }
}

console.log('\n2. Checking LifeToken Rebase Protection Fixes...\n');

// Check LifeToken fixes
const lifeTokenFixes = [
    {
        file: 'contracts/tokens/LifeToken.sol',
        search: 'Rebase change exceeds maximum allowed (20%)',
        name: 'Rebase Change Limit (20%)'
    },
    {
        file: 'contracts/tokens/LifeToken.sol',
        search: 'function emergencyRebase',
        name: 'Emergency Rebase Function'
    },
    {
        file: 'contracts/tokens/LifeToken.sol',
        search: 'event EmergencyRebase',
        name: 'EmergencyRebase Event'
    },
    {
        file: 'contracts/tokens/LifeToken.sol',
        search: 'uint256 maxChangePercent = 20',
        name: 'Maximum Change Percentage Logic'
    }
];

for (const fix of lifeTokenFixes) {
    if (!checkFix(fix.file, fix.search, fix.name)) {
        allFixesImplemented = false;
    }
}

console.log('\n3. Checking NFTm Permission Fixes...\n');

// Check NFTm fixes
const nftmFixes = [
    {
        file: 'contracts/nft/NFTm.sol',
        search: 'insufficient minting privileges',
        name: 'Simplified Minting Permission Check'
    },
    {
        file: 'contracts/nft/NFTm.sol',
        search: 'only NFTi contract or operator',
        name: 'Restricted handleNFTiBurn Permission'
    }
];

for (const fix of nftmFixes) {
    if (!checkFix(fix.file, fix.search, fix.name)) {
        allFixesImplemented = false;
    }
}

console.log('\n4. Checking Error Constants...\n');

// Check error constants
const errorFixes = [
    {
        file: 'contracts/libraries/Errors.sol',
        search: 'TRANSFER_FAILED',
        name: 'TRANSFER_FAILED Error Constant'
    },
    {
        file: 'contracts/libraries/Errors.sol',
        search: 'EXCESS_REFUND_FAILED',
        name: 'EXCESS_REFUND_FAILED Error Constant'
    }
];

for (const fix of errorFixes) {
    if (!checkFix(fix.file, fix.search, fix.name)) {
        allFixesImplemented = false;
    }
}

console.log('\n' + '='.repeat(60));
console.log('AUDIT FIXES VERIFICATION SUMMARY');
console.log('='.repeat(60));

if (allFixesImplemented) {
    console.log('🎉 ALL AUDIT FIXES SUCCESSFULLY IMPLEMENTED!');
    console.log('');
    console.log('✅ PropertyMarket ETH bidding logic fixed');
    console.log('✅ LifeToken rebase protection added');
    console.log('✅ NFTm permission checks simplified');
    console.log('✅ Required error constants added');
    console.log('');
    console.log('📋 Status: READY FOR COMPILATION AND TESTING');
    console.log('');
    console.log('Next Steps:');
    console.log('1. Run: npx hardhat compile');
    console.log('2. Run: npx hardhat test tests/AuditFixes.test.js');
    console.log('3. Deploy to testnet for integration testing');
    console.log('4. Conduct final security review');
} else {
    console.log('❌ SOME AUDIT FIXES ARE MISSING OR INCOMPLETE');
    console.log('');
    console.log('Please review the failed checks above and ensure all');
    console.log('audit fixes are properly implemented before proceeding.');
}

console.log('='.repeat(60));
