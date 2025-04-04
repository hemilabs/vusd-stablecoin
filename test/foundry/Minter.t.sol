// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "../../lib/forge-std/src/Test.sol";
import "../../contracts/Minter.sol";
import "../../contracts/VUSD.sol";
import "../../contracts/interfaces/chainlink/IAggregatorV3.sol";
import "./mock/MockChainlinkOracle.sol";

contract MinterTest is Test {
    VUSD vusd;
    Minter minter;
    address governor;
    address alice = address(0x111);
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant cDAI = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    MockChainlinkOracle mockOracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("NODE_URL"), vm.envUint("FORK_BLOCK_NUMBER"));
        governor = address(this);
        vusd = new VUSD(address(0x222));
        minter = new Minter(address(vusd), type(uint256).max);
        mockOracle = new MockChainlinkOracle(0.999e8);
        vusd.updateMinter(address(minter));
        minter.removeWhitelistedToken(DAI);
        minter.addWhitelistedToken(DAI, cDAI, address(mockOracle));
    }

    function testAddAndRemoveWhitelistedToken() public {
        minter.removeWhitelistedToken(DAI);
        assertFalse(minter.isWhitelistedToken(DAI), "Token should not be whitelisted");

        minter.addWhitelistedToken(DAI, cDAI, address(mockOracle));
        assertTrue(minter.isWhitelistedToken(DAI), "Token should be whitelisted");
    }

    function testUpdateMintingFee() public {
        uint256 newFee = 500;
        minter.updateMintingFee(newFee);
        assertEq(minter.mintingFee(), newFee, "Minting fee should be updated");
    }

    function testStalePeriod() public {
        uint256 newStalePeriod = 3600;
        minter.updateStalePeriod(newStalePeriod);
        assertEq(minter.stalePeriod(), newStalePeriod, "Stale period should be updated");

        // Test for stale price
        vm.warp(block.timestamp + newStalePeriod + 1);
        vm.expectRevert("oracle-price-is-stale");
        minter.calculateMintage(DAI, 1000 ether);
    }

    function testUpdateMaxMintAmount() public {
        uint256 newMintLimit = 1000 ether;
        minter.updateMaxMintAmount(newMintLimit);
        assertEq(minter.maxMintLimit(), newMintLimit, "Max mint limit should be updated");
    }

    function testUpdatePriceDeviationLimit() public {
        uint256 newDeviationLimit = 500;
        minter.updatePriceTolerance(newDeviationLimit);
        assertEq(minter.priceTolerance(), newDeviationLimit, "Price deviation limit should be updated");
    }

    function testMintFailWithPriceDeviation() public {
        minter.updatePriceTolerance(0); // 0% deviation limit
        uint256 _amount = 10 ether;
        deal(DAI, address(this), _amount);
        IERC20(DAI).approve(address(minter), _amount);
        vm.expectRevert("oracle-price-exceed-tolerance");
        minter.mint(DAI, _amount, 1, address(this));
    }

    function testCalculateMintage() public {
        uint256 amount = 10 ether;
        int256 price = 0.9998e8;
        mockOracle.updatePrice(price);
        uint256 fee = minter.mintingFee();
        uint256 maxFee = minter.MAX_BPS();
        uint256 actualMintage = minter.calculateMintage(DAI, amount);
        uint256 amountAfterFee = amount - ((amount * fee) / maxFee);
        uint256 expectedMintage = (uint256(price) * amountAfterFee) / (10 ** mockOracle.decimals());
        assertEq(actualMintage, expectedMintage, "Incorrect mintage calculation");
    }

    function testMintVUSD() public {
        uint256 amount = 1000 ether;
        deal(DAI, address(this), 10 * amount);
        IERC20(DAI).approve(address(minter), amount);
        uint256 expectedVUSD = minter.calculateMintage(DAI, amount);
        minter.mint(DAI, amount, 1, address(this));
        uint256 vusdBalance = vusd.balanceOf(address(this));
        assertEq(vusdBalance, expectedVUSD, "Incorrect VUSD minted");
    }

    function testSlippage() public {
        uint256 amount = 1000 ether;
        deal(DAI, address(this), 10 * amount);
        IERC20(DAI).approve(address(minter), amount);
        // throw error if slippage is not handled
        vm.expectRevert("mint-amount-is-less-than-minimum");
        minter.mint(DAI, amount, amount + 1, address(this));
    }

    function testMintVUSDWithFee() public {
        uint256 amount = 1000 ether;
        minter.updateMintingFee(5);
        deal(DAI, address(this), amount);
        IERC20(DAI).approve(address(minter), amount);
        uint256 expectedVUSD = minter.calculateMintage(DAI, amount);
        minter.mint(DAI, amount, 1, address(this));
        uint256 vusdBalance = vusd.balanceOf(address(this));
        assertEq(vusdBalance, expectedVUSD, "Incorrect VUSD minted");
    }

    function testGovernorCanMint() public {
        uint256 amount = 1000 ether;
        uint256 initialSupply = vusd.totalSupply();
        minter.mint(amount);
        uint256 newSupply = vusd.totalSupply();
        assertEq(newSupply, initialSupply + amount, "Governor should be able to mint VUSD");
    }

    function testNonGovernorCannotMint() public {
        uint256 amount = 1000 ether;
        vm.prank(alice);
        vm.expectRevert("caller-is-not-the-governor");
        minter.mint(amount);
    }

    function testMintMaxAvailableVUSD() public {
        uint256 amount = 1000 ether;

        deal(DAI, alice, amount);
        IERC20(DAI).approve(address(minter), amount);

        uint256 expectedVUSD = minter.calculateMintage(DAI, amount);
        minter.updateMaxMintAmount(expectedVUSD / 2);

        vm.startPrank(alice);

        IERC20(DAI).approve(address(minter), amount);
        vm.expectRevert("mint-limit-reached");
        minter.mint(DAI, amount, 1, address(this));
    }

    function testCalculateMintageWithPriceVariations() public {
        minter.updatePriceTolerance(300);
        uint256 amountIn = 1000 * 1e18; // 1000 tokens
        MockChainlinkOracle(mockOracle).updatePrice(1.0001e8);
        uint256 mintage = minter.calculateMintage(DAI, amountIn);
        // When price > 1 USD, mintage should equal amountIn
        assertEq(mintage, amountIn, "Mintage should equal amountIn when price > 1 USD");

        int256 price = 0.98 * 1e8;
        MockChainlinkOracle(mockOracle).updatePrice(price);

        uint256 mintage2 = minter.calculateMintage(DAI, amountIn);
        require(price >= 0, "Price must be non-negative");
        uint256 expectedMintage2 = (amountIn * uint256(price)) / 1e8;
        assertEq(mintage2, expectedMintage2, "Mintage should be scaled by price when price < 1 USD");
    }
}
