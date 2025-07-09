require("dotenv").config();
const fs = require("node:fs");

const modules = [
  { address: process.env.NEXT_PUBLIC_MODULE_ADDRESS, name: "cpmm" },
  { address: process.env.NEXT_PUBLIC_MODULE_ADDRESS, name: "cpmm_utils" },
  { address: process.env.NEXT_PUBLIC_MODULE_ADDRESS, name: "market" },
  { address: process.env.NEXT_PUBLIC_MODULE_ADDRESS, name: "config" },
];

async function getAbi() {
  // Wait for 5 seconds to ensure the module is deployed
  await new Promise((resolve) => setTimeout(resolve, 5000));
  modules.forEach((module) => {
    const url = `https://fullnode.${process.env.NEXT_PUBLIC_APP_NETWORK}.aptoslabs.com/v1/accounts/${module.address}/module/${module.name}`;
    fetch(url)
      .then((response) => response.json())
      .then((response) => {
        const abi = response.abi;
        const abiString = `export const ${module.name.toUpperCase()}_ABI = ${JSON.stringify(abi)} as const;`;
        fs.writeFileSync(`../../apps/platform/lib/abis/${module.name}_abi.ts`, abiString);
        console.log(`${module.name} ABI saved to apps/platform/lib/abis/${module.name}_abi.ts`);
      })
      .catch((error) => {
        console.error("Error fetching ABI:", error);
      });
  });
}

getAbi();
