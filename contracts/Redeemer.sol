// SPDX-License-Identifier: MIT

pragma solidity 0.8.3;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "./interfaces/chainlink/IAggregatorV3.sol";
import "./interfaces/IVUSD.sol";
import "./interfaces/ITreasury.sol";

/// @title VUSD Redeemer, User can redeem their VUSD with any supported tokens
contract Redeemer is Context, ReentrancyGuard {
    string public constant NAME = "VUSD-Redeemer";
    string public constant VERSION = "1.4.2";

    IVUSD public immutable vusd;
    uint8 public immutable vusdDecimals;

    uint256 public redeemFee = 30; // Default 0.3% fee
    uint256 public constant MAX_REDEEM_FEE = 10_000; // 10_000 = 100%
    uint256 public priceTolerance = 100; // Default 1% based on BPS
    uint256 public stalePeriod = 1 days;

    event UpdatedRedeemFee(uint256 previousRedeemFee, uint256 newRedeemFee);
    event UpdatedPriceTolerance(uint256 previousTolerance, uint256 newTolerance);
    event UpdatedStalePeriod(uint256 previousStalePeriod, uint256 newStalePeriod);

    constructor(address _vusd) {
        require(_vusd != address(0), "vusd-address-is-zero");
        vusd = IVUSD(_vusd);
        vusdDecimals = IERC20Metadata(_vusd).decimals();
    }

    modifier onlyGovernor() {
        require(_msgSender() == governor(), "caller-is-not-the-governor");
        _;
    }

    ////////////////////////////// Only Governor //////////////////////////////

    /// @notice Update redeem fee
    function updateRedeemFee(uint256 _newRedeemFee) external onlyGovernor {
        require(_newRedeemFee <= MAX_REDEEM_FEE, "redeem-fee-limit-reached");
        uint256 _previousRedeemFee = redeemFee;
        require(_previousRedeemFee != _newRedeemFee, "same-redeem-fee");
        redeemFee = _newRedeemFee;
        emit UpdatedRedeemFee(_previousRedeemFee, _newRedeemFee);
    }

    /// @notice Update price tolerance
    function updatePriceTolerance(uint256 _newTolerance) external onlyGovernor {
        require(_newTolerance <= MAX_REDEEM_FEE, "price-tolerance-is-invalid");
        uint256 _previousTolerance = priceTolerance;
        require(_previousTolerance != _newTolerance, "same-tolerance");
        priceTolerance = _newTolerance;
        emit UpdatedPriceTolerance(_previousTolerance, _newTolerance);
    }

    /// @notice Update stale period
    function updateStalePeriod(uint256 _newStalePeriod) external onlyGovernor {
        require(_newStalePeriod > 0, "stale-period-is-invalid");
        uint256 _currentStalePeriod = stalePeriod;
        require(_currentStalePeriod != _newStalePeriod, "same-stale-period");
        emit UpdatedStalePeriod(_currentStalePeriod, _newStalePeriod);
        stalePeriod = _newStalePeriod;
    }

    ///////////////////////////////////////////////////////////////////////////

    /**
     * @notice Redeem token and burn VUSD amount less redeem fee, if any.
     * @param _token Token to redeem, it should be 1 of the supported tokens from treasury.
     * @param _vusdAmount VUSD amount to burn. VUSD will be burnt from caller
     * @param _tokenReceiver Address of token receiver
     */
    function redeem(
        address _token,
        uint256 _vusdAmount,
        uint256 _minAmountOut,
        address _tokenReceiver
    ) external nonReentrant {
        _redeem(_token, _vusdAmount, _minAmountOut, _tokenReceiver);
    }

    /**
     * @notice Current redeemable amount for given token and vusdAmount.
     * If token is not supported by treasury it will return 0.
     * If vusdAmount is higher than current total redeemable of token it will return 0.
     * @param _token Token to redeem
     * @param _vusdAmount VUSD amount to burn
     */
    function redeemable(address _token, uint256 _vusdAmount) external view returns (uint256) {
        ITreasury _treasury = ITreasury(treasury());
        if (_treasury.isWhitelistedToken(_token)) {
            uint256 _redeemable = _calculateRedeemable(_token, _vusdAmount);
            return _redeemable > redeemable(_token) ? 0 : _redeemable;
        }
        return 0;
    }

    /// @dev Current redeemable amount for given token
    function redeemable(address _token) public view returns (uint256) {
        return ITreasury(treasury()).withdrawable(_token);
    }

    /// @dev Governor is defined in VUSD token contract only
    function governor() public view returns (address) {
        return vusd.governor();
    }

    /// @dev Treasury is defined in VUSD token contract only
    function treasury() public view returns (address) {
        return vusd.treasury();
    }

    function _redeem(
        address _token,
        uint256 _vusdAmount,
        uint256 _minAmountOut,
        address _tokenReceiver
    ) internal {
        uint256 _redeemable = _calculateRedeemable(_token, _vusdAmount);
        require(_redeemable >= _minAmountOut, "redeemable-amount-is-less-than-minimum");
        vusd.burnFrom(_msgSender(), _vusdAmount);
        ITreasury(treasury()).withdraw(_token, _redeemable, _tokenReceiver);
    }

    /**
     * @notice Calculate redeemable amount based on oracle price and redeemFee, if any.
     * Also covert 18 decimal VUSD amount to _token defined decimal amount.
     * @return Token amount that user will get after burning vusdAmount
     */
    function _calculateRedeemable(address _token, uint256 _vusdAmount) internal view returns (uint256) {
        IAggregatorV3 _oracle = IAggregatorV3(ITreasury(treasury()).oracles(_token));
        (, int256 _price, , uint256 _updatedAt, ) = IAggregatorV3(_oracle).latestRoundData();
        require(block.timestamp - _updatedAt < stalePeriod, "oracle-price-is-stale");
        uint256 _latestPrice = uint256(_price);
        uint8 _oracleDecimal = IAggregatorV3(_oracle).decimals();

        // Token is expected to be stable coin only. Ideal price is 1 USD
        uint256 _oneUSD = 10**_oracleDecimal;
        uint256 _tolerance = (_oneUSD * priceTolerance) / MAX_REDEEM_FEE;
        uint256 _priceUpperBound = _oneUSD + _tolerance;
        uint256 _priceLowerBound = _oneUSD - _tolerance;

        require(_latestPrice <= _priceUpperBound && _latestPrice >= _priceLowerBound, "price-tolerance-exceeded");
        uint256 _redeemable = _latestPrice < _oneUSD ? _vusdAmount : (_vusdAmount * _oneUSD) / _latestPrice;
        uint256 _redeemFee = redeemFee;
        if (_redeemFee != 0) {
            _redeemable -= (_redeemable * _redeemFee) / MAX_REDEEM_FEE;
        }
        // convert redeemable to _token defined decimal
        return _redeemable / 10**(vusdDecimals - IERC20Metadata(_token).decimals());
    }
}
