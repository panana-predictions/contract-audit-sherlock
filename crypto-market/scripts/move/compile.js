require("dotenv").config();
const cli = require("@aptos-labs/ts-sdk/dist/common/cli/index.js");

async function compile() {
  const move = new cli.Move();

  await move.compile({
    packageDirectoryPath: "@repo/contracts/share-market",
    namedAddresses: {
      owner: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
      panana: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
    },
  });
}
compile();
