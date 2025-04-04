// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

contract MockChainlinkOracle {
    int256 private price;
    uint256 updatedAt = block.timestamp;

    constructor(int256 _price) {
        price = _price;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, updatedAt, 0);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function updatePrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }
}
