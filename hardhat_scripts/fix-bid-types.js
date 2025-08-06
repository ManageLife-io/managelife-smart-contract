const fs = require('fs');

// Read the contract file
let content = fs.readFileSync('contracts/market/PropertyMarket.sol', 'utf8');

// Replace all Bid type references with BidManagement.Bid
const replacements = [
    { from: /\bBid\s+storage\b/g, to: 'BidManagement.Bid storage' },
    { from: /\bBid\s+memory\b/g, to: 'BidManagement.Bid memory' },
    { from: /\bBid\[\]\s+storage\b/g, to: 'BidManagement.Bid[] storage' },
    { from: /\bBid\[\]\s+memory\b/g, to: 'BidManagement.Bid[] memory' },
    { from: /new\s+Bid\(/g, to: 'new BidManagement.Bid(' },
    { from: /returns\s*\(\s*Bid\s+memory\s*\)/g, to: 'returns (BidManagement.Bid memory)' },
    { from: /returns\s*\(\s*Bid\[\]\s+memory/g, to: 'returns (BidManagement.Bid[] memory' }
];

let modified = false;
replacements.forEach(replacement => {
    const newContent = content.replace(replacement.from, replacement.to);
    if (newContent !== content) {
        content = newContent;
        modified = true;
        console.log(`Applied replacement: ${replacement.from} -> ${replacement.to}`);
    }
});

if (modified) {
    fs.writeFileSync('contracts/market/PropertyMarket.sol', content);
    console.log('✅ All Bid type references have been updated');
} else {
    console.log('ℹ️ No changes needed');
}
