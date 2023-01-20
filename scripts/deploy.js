const { getNamedAccounts, ethers } = require("hardhat")
const { getWeth, AMOUNT } = require("../scripts/getWeth")

async function main() {
  await getWeth()
  const { deployer } = await getNamedAccounts()
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.log(error), process.exit(1)
  })
