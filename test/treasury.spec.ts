import {ethers} from "hardhat";
import chai from "chai";
import {VUSD, VUSD__factory, Minter, Minter__factory, Treasury, Treasury__factory} from "../typechain";
import {BigNumber} from "@ethersproject/bignumber";
import tokenSwapper from "./utils/tokenSwapper";
import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import Address from "./utils/address";

const {expect} = chai;

const ZERO_ADDRESS = Address.ZERO;
const DAI_ADDRESS = Address.DAI;
const USDC_ADDRESS = Address.USDC;
const USDT_ADDRESS = Address.USDT;
const WETH_ADDRESS = Address.WETH;

const cDAI_ADDRESS = Address.cDAI;
const cUSDC_ADDRESS = Address.cUSDC;
const cETH_ADDRESS = Address.cETH;

const DAI_USD = Address.DAI_USD;
const ETH_USD = Address.ETH_USD;

describe("VUSD Treasury", async function () {
  let vusd: VUSD, minter: Minter, treasury: Treasury;
  let signers, keeper;

  async function mintVUSD(toToken: string, caller: SignerWithAddress, amountIn?: string): Promise<BigNumber> {
    const inputAmount = amountIn || "1";
    const amount = await tokenSwapper.swapEthForToken(inputAmount, toToken, caller);
    const Token = await ethers.getContractAt("ERC20", toToken);
    await Token.connect(caller).approve(minter.address, amount);
    await minter.connect(caller)["mint(address,uint256)"](toToken, amount);
    return amount;
  }

  async function mineBlocks(blocksToMine: number): Promise<void> {
    const currentBlockNumber = await ethers.provider.getBlockNumber();
    const target = currentBlockNumber + blocksToMine;
    while ((await ethers.provider.getBlockNumber()) < target) {
      await ethers.provider.send("evm_mine", []);
    }
  }

  async function deployTreasury(vusd: VUSD, caller: SignerWithAddress) {
    const treasuryFactory = (await ethers.getContractFactory("Treasury", caller)) as Treasury__factory;
    const treasury: Treasury = await treasuryFactory.deploy(vusd.address);
    expect(treasury.address).to.be.properAddress;
    await vusd.updateTreasury(treasury.address);
    treasury.addKeeper(keeper.address);
    return treasury;
  }

  beforeEach(async function () {
    signers = await ethers.getSigners();
    keeper = signers[1];
    const vusdFactory = (await ethers.getContractFactory("VUSD", signers[0])) as VUSD__factory;
    vusd = await vusdFactory.deploy(signers[8].address);
    expect(vusd.address).to.be.properAddress;

    const minterFactory = (await ethers.getContractFactory("Minter", signers[0])) as Minter__factory;
    minter = await minterFactory.deploy(vusd.address, ethers.constants.MaxUint256);
    expect(minter.address).to.be.properAddress;
    await vusd.updateMinter(minter.address);

    treasury = await deployTreasury(vusd, signers[0]);
  });

  context("Check Withdrawable", function () {
    it("Should return zero withdrawable when no balance", async function () {
      expect(await treasury.withdrawable(DAI_ADDRESS)).to.be.eq(0, "Withdrawable should be zero");
    });

    it("Should return valid withdrawable", async function () {
      await mintVUSD(USDC_ADDRESS, signers[3]);
      expect(await treasury.withdrawable(USDC_ADDRESS)).to.be.gt(0, "Withdrawable should be > 0");
    });

    it("Should return zero withdrawable for non supporting token", async function () {
      expect(await treasury.withdrawable(WETH_ADDRESS)).to.be.eq(0, "Withdrawable should be zero");
    });
  });

  context("Withdraw token", function () {
    it("Should revert if caller is neither governor nor redeemer", async function () {
      await mintVUSD(DAI_ADDRESS, signers[4]);
      const amountToWithdraw = ethers.utils.parseUnits("1000", "ether"); // 1000 DAI
      const tx = treasury.connect(signers[4])["withdraw(address,uint256)"](DAI_ADDRESS, amountToWithdraw);
      await expect(tx).to.be.revertedWith("caller-is-not-authorized");
    });

    it("Should revert if token is not supported", async function () {
      const tx = treasury["withdraw(address,uint256)"](WETH_ADDRESS, "1000");
      await expect(tx).to.be.revertedWith("token-is-not-supported");
    });

    it("Should allow withdraw by redeemer", async function () {
      await treasury.updateRedeemer(signers[3].address);
      await mintVUSD(USDC_ADDRESS, signers[3]);
      const amountToWithdraw = ethers.utils.parseUnits("1000", "mwei"); // 1000 USDT
      const USDT = await ethers.getContractAt("ERC20", USDC_ADDRESS);
      expect(await USDT.balanceOf(signers[3].address)).to.be.eq(0, "Governor balance should be zero");
      await treasury.connect(signers[3])["withdraw(address,uint256)"](USDC_ADDRESS, amountToWithdraw);
      expect(await USDT.balanceOf(signers[3].address)).to.be.eq(amountToWithdraw, "Incorrect USDT balance");
    });

    /* eslint-disable no-unexpected-multiline */
    it("Should allow withdraw to another address by redeemer", async function () {
      await treasury.updateRedeemer(signers[3].address);
      await mintVUSD(DAI_ADDRESS, signers[4]);
      const amountToWithdraw = ethers.utils.parseUnits("1000", "ether"); // 1000 DAI
      const DAI = await ethers.getContractAt("ERC20", DAI_ADDRESS);
      expect(await DAI.balanceOf(signers[5].address)).to.be.eq(0, "User balance should be zero");

      await treasury
        .connect(signers[3])
        ["withdraw(address,uint256,address)"](DAI_ADDRESS, amountToWithdraw, signers[5].address);
      expect(await DAI.balanceOf(signers[5].address)).to.be.eq(amountToWithdraw, "Incorrect DAI balance");
    });

    it("Should allow withdraw by governor", async function () {
      await mintVUSD(USDC_ADDRESS, signers[2]);
      const amountToWithdraw = ethers.utils.parseUnits("1000", "mwei"); // 1000 USDC
      const USDC = await ethers.getContractAt("ERC20", USDC_ADDRESS);
      expect(await USDC.balanceOf(signers[0].address)).to.be.eq(0, "Governor balance should be zero");
      await treasury["withdraw(address,uint256)"](USDC_ADDRESS, amountToWithdraw);
      expect(await USDC.balanceOf(signers[0].address)).to.be.eq(amountToWithdraw, "Incorrect USDC balance");
    });
  });

  context("WithdrawMulti by governor", function () {
    it("Should allow withdrawMulti by governor", async function () {
      await mintVUSD(DAI_ADDRESS, signers[2]);
      const amountToWithdraw = ethers.utils.parseUnits("1000", "ether"); // 1000 DAI
      const DAI = await ethers.getContractAt("ERC20", DAI_ADDRESS);
      const balanceBefore = await DAI.balanceOf(signers[0].address);
      await treasury.withdrawMulti([DAI_ADDRESS], [amountToWithdraw]);
      const balanceAfter = await DAI.balanceOf(signers[0].address);
      expect(balanceAfter).to.be.eq(balanceBefore.add(amountToWithdraw), "Incorrect DAI balance");
    });

    it("Should revert withdrawMulti if inputs are bad", async function () {
      const tx = treasury.withdrawMulti([DAI_ADDRESS], []);
      await expect(tx).to.be.revertedWith("input-length-mismatch");
    });
  });

  context("WithdrawAll by governor", function () {
    it("Should allow withdrawAll by governor", async function () {
      await mintVUSD(DAI_ADDRESS, signers[2]);
      const DAI = await ethers.getContractAt("ERC20", DAI_ADDRESS);
      const balanceBefore = await DAI.balanceOf(signers[0].address);
      const withdrawable = await treasury.withdrawable(DAI_ADDRESS);
      await treasury.withdrawAll([DAI_ADDRESS]);
      const balanceAfter = await DAI.balanceOf(signers[0].address);
      // Checking gte as actual will be having little extra due to earning from 1 block
      expect(balanceAfter).to.be.gte(balanceBefore.add(withdrawable), "Incorrect DAI balance");
    });

    it("Should revert withdrawAll if token is not supported", async function () {
      const tx = treasury.withdrawAll([WETH_ADDRESS]);
      await expect(tx).to.be.revertedWith("token-is-not-supported");
    });
  });

  context("Claim COMP", function () {
    it("Should claim comp from all cToken markets", async function () {
      await mintVUSD(DAI_ADDRESS, signers[4], "100");
      await mineBlocks(1000);
      const cUSDC = await ethers.getContractAt("ERC20", cUSDC_ADDRESS);
      expect(await cUSDC.balanceOf(treasury.address)).to.be.eq(0, "cUSDC balance should be zero");
      await treasury.claimCompAndConvertTo(USDC_ADDRESS, 1);
      expect(await cUSDC.balanceOf(treasury.address)).to.be.gt(0, "cUSDC balance should be > 0");
    });

    it("Should claim comp via keeper call", async function () {
      await mintVUSD(USDC_ADDRESS, signers[4], "100");
      await mineBlocks(1000);
      const cDAI = await ethers.getContractAt("ERC20", cDAI_ADDRESS);
      expect(await cDAI.balanceOf(treasury.address)).to.be.eq(0, "cDAI balance should be zero");
      await treasury.connect(keeper).claimCompAndConvertTo(DAI_ADDRESS, 1);
      expect(await cDAI.balanceOf(treasury.address)).to.be.gt(0, "cDAI balance should be > 0");
    });

    it("Should revert if token is not supported", async function () {
      const tx = treasury.claimCompAndConvertTo(WETH_ADDRESS, 1);
      await expect(tx).to.be.revertedWith("token-is-not-supported");
    });

    it("Should revert if caller is not authorized", async function () {
      const tx = treasury.connect(signers[6]).claimCompAndConvertTo(WETH_ADDRESS, 1);
      await expect(tx).to.be.revertedWith("caller-is-not-authorized");
    });
  });

  context("Migrate to new treasury", function () {
    it("Should revert if new treasury address is zero", async function () {
      const tx = treasury.migrate(ZERO_ADDRESS);
      await expect(tx).to.be.revertedWith("new-treasury-address-is-zero");
    });
    it("Should revert if vusd doesn't match", async function () {
      // Deploy new treasury
      const treasuryFactory = (await ethers.getContractFactory("Treasury", signers[0])) as Treasury__factory;
      // passing DAI address as VUSD
      const newTreasury = await treasuryFactory.deploy(DAI_ADDRESS);
      const tx = treasury.migrate(newTreasury.address);
      await expect(tx).to.be.revertedWith("vusd-mismatch");
    });
    it("Should transfer all cTokens to new treasury", async function () {
      await mintVUSD(DAI_ADDRESS, signers[4], "100");
      await mintVUSD(USDC_ADDRESS, signers[5], "100");
      const cDAI = await ethers.getContractAt("ERC20", cDAI_ADDRESS);
      const cUSDC = await ethers.getContractAt("ERC20", cUSDC_ADDRESS);
      const cDAIBalance = await cDAI.balanceOf(treasury.address);
      const cUSDCBalance = await cUSDC.balanceOf(treasury.address);

      // Deploy new treasury
      const newTreasury = await deployTreasury(vusd, signers[0]);
      expect(await cDAI.balanceOf(newTreasury.address)).to.be.eq(0, "cDAI balance should be zero");
      expect(await cUSDC.balanceOf(newTreasury.address)).to.be.eq(0, "cUSDC balance should be zero");

      await treasury.migrate(newTreasury.address);
      expect(await cDAI.balanceOf(newTreasury.address)).to.be.eq(cDAIBalance, "cDAI in new treasury is wrong");
      expect(await cUSDC.balanceOf(newTreasury.address)).to.be.eq(cUSDCBalance, "cUSDC in new treasury is wrong");

      expect(await cDAI.balanceOf(treasury.address)).to.be.eq(0, "cDAI balance should be zero");
      expect(await cUSDC.balanceOf(treasury.address)).to.be.eq(0, "cUSDC balance should be zero");
    });
  });

  context("Sweep token", function () {
    it("Should sweep token", async function () {
      const daiAmount = await tokenSwapper.swapEthForToken("1", DAI_ADDRESS, signers[5], treasury.address);
      const DAI = await ethers.getContractAt("ERC20", DAI_ADDRESS);
      const balanceBefore = await DAI.balanceOf(signers[0].address);
      await treasury.sweep(DAI_ADDRESS);
      const balanceAfter = await DAI.balanceOf(signers[0].address);
      await treasury.claimCompAndConvertTo(USDC_ADDRESS, 1);
      expect(balanceAfter.sub(balanceBefore)).to.be.eq(daiAmount, "Sweep token amount is not correct");
    });

    it("Should revert if trying to sweep cToken", async function () {
      const tx = treasury.sweep(cDAI_ADDRESS);
      await expect(tx).to.be.revertedWith("cToken-is-not-allowed-to-sweep");
    });
  });

  context("Update redeemer", function () {
    it("Should revert if caller is not governor", async function () {
      const tx = treasury.connect(signers[4]).updateRedeemer(signers[9].address);
      await expect(tx).to.be.revertedWith("caller-is-not-the-governor");
    });
    it("Should revert if setting zero address as redeemer", async function () {
      const tx = treasury.updateRedeemer(ZERO_ADDRESS);
      await expect(tx).to.be.revertedWith("redeemer-address-is-zero");
    });

    it("Should add new redeemer", async function () {
      const redeemer = await treasury.redeemer();
      const newRedeemer = signers[9].address;
      const tx = treasury.updateRedeemer(newRedeemer);
      await expect(tx).to.emit(treasury, "UpdatedRedeemer").withArgs(redeemer, newRedeemer);
      expect(await treasury.redeemer()).to.eq(newRedeemer, "Redeemer update failed");
    });

    it("Should revert if setting same redeemer", async function () {
      await treasury.updateRedeemer(signers[9].address);
      const tx = treasury.updateRedeemer(signers[9].address);
      await expect(tx).to.be.revertedWith("same-redeemer");
    });
  });

  context("Update keeper", function () {
    it("Should revert if caller is not governor", async function () {
      const tx = treasury.connect(signers[4]).addKeeper(signers[9].address);
      await expect(tx).to.be.revertedWith("caller-is-not-the-governor");
    });
    it("Should revert if setting zero address as keeper", async function () {
      const tx = treasury.addKeeper(ZERO_ADDRESS);
      await expect(tx).to.be.revertedWith("keeper-address-is-zero");
    });

    it("Should add new keeper", async function () {
      expect((await treasury.keepers()).length).to.eq(2, "incorrect keeper count");
      const newKeeper = signers[10].address;
      await treasury.addKeeper(newKeeper);
      expect((await treasury.keepers()).length).to.eq(3, "add keeper failed");
    });

    it("Should remove a keeper", async function () {
      await treasury.removeKeeper(keeper.address);
      expect((await treasury.keepers()).length).to.eq(1, "remove keeper failed");
    });
  });

  context("Update swap manager", function () {
    it("Should revert if caller is not governor", async function () {
      const tx = treasury.connect(signers[4]).updateSwapManager(signers[7].address);
      await expect(tx).to.be.revertedWith("caller-is-not-the-governor");
    });
    it("Should revert if setting zero address as swap manager", async function () {
      const tx = treasury.updateSwapManager(ZERO_ADDRESS);
      await expect(tx).to.be.revertedWith("swap-manager-address-is-zero");
    });

    it("Should add new swap manager", async function () {
      const swapManager = await treasury.swapManager();
      const newSwapManager = swapManager;
      const tx = treasury.updateSwapManager(newSwapManager);
      await expect(tx).to.emit(treasury, "UpdatedSwapManager").withArgs(swapManager, newSwapManager);
      expect(await treasury.swapManager()).to.eq(newSwapManager, "Swap manager update failed");
    });
  });

  context("Update token whitelist", function () {
    context("Add token in whitelist", function () {
      it("Should revert if caller is not governor", async function () {
        const tx = treasury.connect(signers[4]).addWhitelistedToken(DAI_ADDRESS, cDAI_ADDRESS, DAI_USD);
        await expect(tx).to.be.revertedWith("caller-is-not-the-governor");
      });

      it("Should revert if setting zero address for token", async function () {
        const tx = treasury.addWhitelistedToken(ZERO_ADDRESS, cETH_ADDRESS, ETH_USD);
        await expect(tx).to.be.revertedWith("token-address-is-zero");
      });

      it("Should revert if setting zero address for cToken", async function () {
        const tx = treasury.addWhitelistedToken(WETH_ADDRESS, ZERO_ADDRESS, ETH_USD);
        await expect(tx).to.be.revertedWith("cToken-address-is-zero");
      });

      it("Should add token address in whitelist", async function () {
        await treasury.addWhitelistedToken(WETH_ADDRESS, cETH_ADDRESS, ETH_USD);
        expect((await treasury.whitelistedTokens()).length).to.be.equal(4, "Address added successfully");
        expect((await treasury.cTokenList()).length).to.be.equal(4, "cToken address added successfully");
        expect(await treasury.cTokens(WETH_ADDRESS)).to.be.eq(cETH_ADDRESS, "Wrong cToken");
      });

      it("Should revert if address already exist in list", async function () {
        await expect(treasury.addWhitelistedToken(DAI_ADDRESS, cDAI_ADDRESS, DAI_USD)).to.be.revertedWith(
          "add-in-list-failed"
        );
      });
    });
    context("Remove token address from whitelist", function () {
      it("Should revert if caller is not governor", async function () {
        const tx = treasury.connect(signers[4]).removeWhitelistedToken(DAI_ADDRESS);
        await expect(tx).to.be.revertedWith("caller-is-not-the-governor");
      });

      it("Should remove token from whitelist", async function () {
        await treasury.removeWhitelistedToken(USDT_ADDRESS);
        expect((await treasury.whitelistedTokens()).length).to.be.equal(2, "Address removed successfully");
        expect((await treasury.cTokenList()).length).to.be.equal(2, "cToken address removed successfully");
        expect(await treasury.cTokens(USDT_ADDRESS)).to.be.eq(ZERO_ADDRESS, "CToken should be removed");
      });

      it("Should revert if token not in list", async function () {
        await expect(treasury.removeWhitelistedToken(WETH_ADDRESS)).to.be.revertedWith("remove-from-list-failed");
      });
    });
  });
});
