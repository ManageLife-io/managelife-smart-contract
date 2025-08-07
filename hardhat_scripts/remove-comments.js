const fs = require('fs');

// Read the contract file
let content = fs.readFileSync('contracts/market/PropertyMarket.sol', 'utf8');

// Remove section divider comments
const patterns = [
    /\s*\/\/ ==========.*==========\s*\n/g,
    /\s*\/\/ =============================\s*\n/g,
    /\s*\/\/ MA2-\d+.*\n/g,
    /\s*\/\/ =============================\s*\n/g
];

let modified = false;
patterns.forEach(pattern => {
    const newContent = content.replace(pattern, '\n');
    if (newContent !== content) {
        content = newContent;
        modified = true;
        console.log(`Removed pattern: ${pattern}`);
    }
});

// Remove empty lines (multiple consecutive newlines)
content = content.replace(/\n\s*\n\s*\n/g, '\n\n');

if (modified) {
    fs.writeFileSync('contracts/market/PropertyMarket.sol', content);
    console.log('✅ Comments removed successfully');
} else {
    console.log('ℹ️ No changes needed');
}
