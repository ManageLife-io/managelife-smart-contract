const fs = require('fs');

// Read the contract file
let content = fs.readFileSync('contracts/market/PropertyMarket.sol', 'utf8');

// Restore all BidManagement.Bid type references back to Bid
const replacements = [
    { from: /BidManagement\.Bid\s+storage/g, to: 'Bid storage' },
    { from: /BidManagement\.Bid\s+memory/g, to: 'Bid memory' },
    { from: /BidManagement\.Bid\[\]\s+storage/g, to: 'Bid[] storage' },
    { from: /BidManagement\.Bid\[\]\s+memory/g, to: 'Bid[] memory' },
    { from: /new\s+BidManagement\.Bid\(/g, to: 'new Bid(' },
    { from: /returns\s*\(\s*BidManagement\.Bid\s+memory\s*\)/g, to: 'returns (Bid memory)' },
    { from: /returns\s*\(\s*BidManagement\.Bid\[\]\s+memory/g, to: 'returns (Bid[] memory' }
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
    console.log('✅ All BidManagement.Bid type references have been restored to Bid');
} else {
    console.log('ℹ️ No changes needed');
}
