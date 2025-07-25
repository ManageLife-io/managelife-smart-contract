const fs = require('fs');

// Read the contract file
let content = fs.readFileSync('contracts/market/PropertyMarket.sol', 'utf8');

// Remove detailed function documentation comments
const patterns = [
    // Remove @notice, @dev, @param, @return comments
    /\s*\/\/\/ @notice.*\n/g,
    /\s*\/\/\/ @dev.*\n/g,
    /\s*\/\/\/ @param.*\n/g,
    /\s*\/\/\/ @return.*\n/g,
    // Remove multi-line comment blocks
    /\s*\/\*\*[\s\S]*?\*\/\s*\n/g,
    // Remove single line comments that are just descriptions
    /\s*\/\/ [A-Z][a-z].*\n/g,
    // Remove empty comment lines
    /\s*\/\/\s*\n/g,
];

let totalRemoved = 0;
patterns.forEach((pattern, index) => {
    const before = content.length;
    content = content.replace(pattern, '\n');
    const after = content.length;
    const removed = before - after;
    if (removed > 0) {
        totalRemoved += removed;
        console.log(`Pattern ${index + 1}: Removed ${removed} characters`);
    }
});

// Remove multiple consecutive newlines
content = content.replace(/\n\s*\n\s*\n/g, '\n\n');

// Remove trailing whitespace
content = content.replace(/[ \t]+$/gm, '');

fs.writeFileSync('contracts/market/PropertyMarket.sol', content);
console.log(`✅ Total removed: ${totalRemoved} characters`);
console.log(`✅ Comments cleanup completed`);
