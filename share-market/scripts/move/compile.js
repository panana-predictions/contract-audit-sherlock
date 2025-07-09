require("dotenv").config();
const cli = require("@aptos-labs/ts-sdk/dist/common/cli/index.js");

async function compile() {
  const move = new cli.Move();

  await move.compile({
    packageDirectoryPath: "@repo/contract",
    namedAddresses: {
      panana: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
      amm_address: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
      admin: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
      user1: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
      user2: process.env.NEXT_MODULE_PUBLISHER_ACCOUNT_ADDRESS,
    },
  });
}
compile();
