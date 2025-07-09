require("dotenv").config();

const cli = require("@aptos-labs/ts-sdk/dist/common/cli/index.js");
const path = require("path");
const fs = require("fs");

async function test() {
  const packagePath = path.resolve(__dirname, "..", "..", ".");
  
  const coverageDir = path.join(packagePath, ".coverage");
  if (!fs.existsSync(coverageDir)) {
    fs.mkdirSync(coverageDir, { recursive: true });
  }

  const move = new cli.Move();

  await move.test({
    packageDirectoryPath: packagePath,
    namedAddresses: {
      panana: '0x100',
      amm_address: "0xaaa",
      admin: "0xcafe3",
      user1: "0xcafe1",
      user2: "0xcafe2",
    },
    extraArguments: ["--skip-fetch-latest-git-deps", "--coverage"],
  });
}

test().catch(console.error);
