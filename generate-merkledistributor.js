const program = require("commander");
const fs = require("fs");
const nunjucks = require("nunjucks");


program.version("0.0.1");
program.option(
    "-t, --template <template>",
    "TokenHub template file",
    "./contracts/MerkleDistributor.template"
);

program.option(
    "-o, --output <output-file>",
    "MerkleDistributor.sol",
    "./contracts/MerkleDistributor.sol"
)

program.option("--network <network>",
    "network",
    "mainnet");

program.parse(process.argv);

const data = {
    network: program.network,
};
const templateString = fs.readFileSync(program.template).toString();
const resultString = nunjucks.renderString(templateString, data);
fs.writeFileSync(program.output, resultString);
console.log("MerkleDistributor file updated.");
