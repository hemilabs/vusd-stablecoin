// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "../../lib/forge-std/src/Test.sol";
import "../../contracts/Redeemer.sol";
import "../../contracts/VUSD.sol";
import "../../contracts/interfaces/chainlink/IAggregatorV3.sol";
import "./mock/MockChainlinkOracle.sol";
import "./mock/MockTreasury.sol";

contract RedeemerTest is Test {
    VUSD vusd;
    Redeemer redeemer;
    MockTreasury treasury;
    address alice = address(0x111);
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant cDAI = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    MockChainlinkOracle mockOracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("NODE_URL"), vm.envUint("FORK_BLOCK_NUMBER"));
        treasury = new MockTreasury();
        vusd = new VUSD(address(treasury));
        vusd.updateMinter(address(this));
        vusd.mint(alice, 10000 ether);
        redeemer = new Redeemer(address(vusd));
        mockOracle = new MockChainlinkOracle(1.01e8);
        console.log("VUSD balance: %s", vusd.balanceOf(alice));
        deal(DAI, address(treasury), 1000 ether);
        treasury.setOracle(DAI, address(mockOracle));
    }

    function testUpdatePriceTolerance() public {
        uint256 newTolerance = 1000;
        redeemer.updatePriceTolerance(newTolerance);
        assertEq(redeemer.priceTolerance(), newTolerance, "Price tolerance should be updated");
    }

    function testRedeemWithPriceToleranceExceeded() public {
        redeemer.updatePriceTolerance(0);
        vm.expectRevert("price-tolerance-exceeded");
        redeemer.redeem(DAI, 100, 1, address(0x123));
    }

    function testRedeemWithinPriceTolerance() public {
        uint256 amount = 500 ether;
        uint256 redeemableAmount = redeemer.redeemable(DAI, amount);
        uint256 vusdBalanceBefore = vusd.balanceOf(alice);

        vm.startPrank(alice);
        vusd.approve(address(redeemer), amount);
        redeemer.redeem(DAI, amount, 1, alice);
        vm.stopPrank();

        // assert that vusd balance decrease
        assertEq(vusd.balanceOf(alice), vusdBalanceBefore - amount, "VUSD balance should decrease");
        assertEq(redeemableAmount, IERC20(DAI).balanceOf(alice), "DAI amount should be transferred to user");
    }

    function testRedeemable() public view {
        (, int256 _price,,,) = mockOracle.latestRoundData();
        uint256 vusdAmount = 100 ether;
        uint256 redeemableBeforeFee = (vusdAmount * 1e8) / uint256(_price);
        uint256 expectedRedeemable = redeemableBeforeFee - ((redeemableBeforeFee * redeemer.redeemFee()) / 10000);
        uint256 redeemableAmount = redeemer.redeemable(DAI, vusdAmount);
        assertEq(redeemableAmount, expectedRedeemable, "Redeemable amount should be correct");
    }

    function testSlippage() public {
        uint256 amount = 100 ether;
        uint256 redeemableAmount = redeemer.redeemable(DAI, amount);

        vm.startPrank(alice);
        vusd.approve(address(redeemer), amount);
        vm.expectRevert("redeemable-amount-is-less-than-minimum");
        redeemer.redeem(DAI, amount, redeemableAmount + 1, alice);
        vm.stopPrank();
    }

    function testUpdateRedeemFee() public {
        uint256 newFee = 50;
        redeemer.updateRedeemFee(newFee);
        assertEq(redeemer.redeemFee(), newFee, "Redeem fee should be updated");
    }

    function testStalePeriod() public {
        uint256 newStalePeriod = 3600;
        redeemer.updateStalePeriod(newStalePeriod);
        assertEq(redeemer.stalePeriod(), newStalePeriod, "Stale period should be updated");

        // Test for stale price
        vm.warp(block.timestamp + newStalePeriod + 1);
        vm.expectRevert("oracle-price-is-stale");
        redeemer.redeemable(DAI, 100);
    }

    function testRedeemWithUpdatedFee() public {
        uint256 amount = 10 ether;
        redeemer.updateRedeemFee(0);
        uint256 redeemableWithoutFee = redeemer.redeemable(DAI, amount);
        uint256 newFee = 50; // 0.5%
        redeemer.updateRedeemFee(newFee);
        uint256 expectedRedeemable = redeemableWithoutFee - ((redeemableWithoutFee * newFee) / 10000);

        vm.startPrank(alice);
        vusd.approve(address(redeemer), amount);
        redeemer.redeem(DAI, amount, 1, alice);
        vm.stopPrank();

        uint256 daiBalance = IERC20(DAI).balanceOf(alice);
        assertEq(daiBalance, expectedRedeemable, "Recipient should receive redeemed VUSD with updated fee");
    }

    function testCalculateRedeemableWithPriceVariations() public {
        uint256 amountIn = 1000 * 1e18; // 1000 tokens
        MockChainlinkOracle(mockOracle).updatePrice(0.999e8);
        redeemer.updateRedeemFee(0);
        uint256 redeemable = redeemer.redeemable(DAI, amountIn);
        // When price > 1 USD, mintage should equal amountIn
        assertEq(redeemable, amountIn, "Mintage should equal amountIn when price > 1 USD");

        int256 price = 1.001 * 1e8;
        MockChainlinkOracle(mockOracle).updatePrice(price);

        redeemable = redeemer.redeemable(DAI, amountIn);
        require(price >= 0, "Price must be non-negative");
        uint256 expectedRedeemable = (amountIn * 1e8) / uint256(price);
        assertEq(redeemable, expectedRedeemable, "Mintage should be scaled by price when price < 1 USD");
    }
}
