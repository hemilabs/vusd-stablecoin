// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "../../../contracts//interfaces/ITreasury.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockTreasury is ITreasury {
    mapping(address => address) private tokenOracles;

    function isWhitelistedToken(address) external pure override returns (bool) {
        return true;
    }

    function oracles(address _token) external view override returns (address) {
        return tokenOracles[_token];
    }

    function withdrawable(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function setWhitelistedToken(address _token, bool _whitelisted) external {}

    function setOracle(address _token, address _oracle) external {
        tokenOracles[_token] = _oracle;
    }

    function withdraw(address _token, uint256 _amount, address _receiver) external override {
        IERC20(_token).transfer(_receiver, _amount);
    }

    function withdraw(address _token, uint256 _amount) external override {
        IERC20(_token).transfer(msg.sender, _amount);
    }

    function vusd() external view override returns (address) {}

    function whitelistedTokens() external view override returns (address[] memory) {}
}
