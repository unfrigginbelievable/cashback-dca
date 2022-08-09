//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "aave/contracts/protocol/libraries/types/DataTypes.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

error AaveHelper__DivDecimalsDoNotMatch();
error AaveHelper__MulDecimalsDoNotMatch();
error AaveHelper__SubDecimalsDoNotMatch();
error AaveHelper__AddDecimalsDoNotMatch();
error AaveHelper__NotEnoughToPayBackDebt();
error AaveHelper__SwapDecimalsDoNotMatch();
error AaveHelper__ConversionOutsideBounds();
error AaveHelper__AssetMustHave18Decimals();
error AaveHelper__ConvertUSDCDecimalsDoNotMatch();
error AaveHelper__ConvertAAVEDecimalsDoNotMatch();

contract AaveHelper {
    struct DecimalNumber {
        uint256 number;
        uint256 decimals;
    }

    uint256 public feeConverter = 1e12;
    DecimalNumber public UNI_POOL_FEE = DecimalNumber({number: 3000 * feeConverter, decimals: 18});
    DecimalNumber public MAX_SLIPPAGE = DecimalNumber({number: 10000 * feeConverter, decimals: 18});

    IPool public pool;
    IPriceOracle public oracle;
    ISwapRouter public router;

    function calcNewLoan(DecimalNumber memory _deposits, DecimalNumber memory _loanPercentage)
        internal
        pure
        returns (DecimalNumber memory)
    {
        return fixedMul(_deposits, _loanPercentage);
    }

    /// @dev get price of amount x quoted in y
    /// @notice asset prices should share a common quote asset before conversion (ie. both should be over USD)
    function convertPriceDenomination(
        IERC20Metadata _x,
        IERC20Metadata _y,
        DecimalNumber memory _amountX
    ) internal view returns (DecimalNumber memory) {
        if (_amountX.decimals != 18) {
            revert AaveHelper__AssetMustHave18Decimals();
        }

        DecimalNumber memory _xPriceUSD = getAssetPrice(_x);
        DecimalNumber memory _yPriceUSD = getAssetPrice(_y);

        // (_wethAmount * _xPriceUSD) / _yPriceUSD -> to six decimal places
        DecimalNumber memory _xAmountAsY = fixedDiv(fixedMul(_amountX, _xPriceUSD), _yPriceUSD);

        return _xAmountAsY;
    }

    /*
     * Does all the calculations to borrow
     * Matches old debt amount + flashloan fee + uniswap fee + trade slippage in USD
     */
    function borrowAsset(
        IERC20Metadata _newDebtAsset,
        DecimalNumber memory _oldDebtAssetPriceUSD,
        DecimalNumber memory _amountOldDebtAssetBeforeSwap,
        DecimalNumber memory _paybackAmount,
        uint256 _borrowRateType
    ) internal returns (DecimalNumber memory) {
        DecimalNumber memory _newDebtAssetPriceUSD = getAssetPrice(_newDebtAsset);

        DecimalNumber memory _oldDebtAssetPriceInNewDebtAsset = fixedDiv(
            _oldDebtAssetPriceUSD,
            _newDebtAssetPriceUSD
        );

        DecimalNumber memory _newDebtAssetPriceInOldDebtAsset = fixedDiv(
            _newDebtAssetPriceUSD,
            _oldDebtAssetPriceUSD
        );

        DecimalNumber memory _oldDebtAssetAmountInNewDebtAsset = fixedMul(
            _amountOldDebtAssetBeforeSwap,
            _oldDebtAssetPriceInNewDebtAsset
        );

        DecimalNumber memory _uniFeeInOldDebtAsset = fixedMul(
            UNI_POOL_FEE,
            _amountOldDebtAssetBeforeSwap
        );
        DecimalNumber memory _uniFeeInNewDebtAsset = fixedMul(
            _oldDebtAssetPriceInNewDebtAsset,
            _uniFeeInOldDebtAsset
        );
        DecimalNumber memory _slippage = fixedMul(_oldDebtAssetAmountInNewDebtAsset, MAX_SLIPPAGE);
        DecimalNumber memory _expectedBackInNewDebtAsset = removePrecision(
            fixedAdd(fixedAdd(_oldDebtAssetAmountInNewDebtAsset, _uniFeeInNewDebtAsset), _slippage),
            _newDebtAsset.decimals()
        );

        DecimalNumber memory _newLoanAmount = fixedAdd(
            _expectedBackInNewDebtAsset,
            fixedDiv(_paybackAmount, _newDebtAssetPriceInOldDebtAsset)
        );

        pool.borrow(
            address(_newDebtAsset),
            _newLoanAmount.number,
            _borrowRateType,
            0,
            address(this)
        );

        return _newLoanAmount;
    }

    function repayDebt(
        IERC20Metadata _oldDebtAsset,
        DecimalNumber memory _amountOldDebtAssetBeforeSwap,
        DecimalNumber memory _oldDebtAssetPriceUSD,
        uint256 _rateType
    ) internal returns (DecimalNumber memory _amountRepaid) {
        if (_amountOldDebtAssetBeforeSwap.decimals != 18) {
            revert AaveHelper__AssetMustHave18Decimals();
        }

        if (_oldDebtAssetPriceUSD.decimals != 18) {
            revert AaveHelper__AssetMustHave18Decimals();
        }

        // Check if the amount of debt asset in contract can fully pack back loan
        DecimalNumber memory _totalDebtUSD = getTotalDebt(address(this));
        DecimalNumber memory _totalDebtInOldDebtAsset = fixedDiv(
            _totalDebtUSD,
            _oldDebtAssetPriceUSD
        );

        if (_totalDebtInOldDebtAsset.number > _amountOldDebtAssetBeforeSwap.number) {
            console.log(_totalDebtInOldDebtAsset.number);
            revert AaveHelper__NotEnoughToPayBackDebt();
        }

        // repay the debt if check passes
        _oldDebtAsset.approve(address(pool), _amountOldDebtAssetBeforeSwap.number);
        _amountRepaid = DecimalNumber({
            number: pool.repay(
                address(_oldDebtAsset),
                _amountOldDebtAssetBeforeSwap.number,
                _rateType,
                address(this)
            ),
            decimals: _oldDebtAsset.decimals()
        });
    }

    function swapAssets(
        IERC20Metadata _inAsset,
        IERC20Metadata _outAsset,
        DecimalNumber memory _outAmount
    ) internal returns (uint256) {
        if (_outAsset.decimals() != _outAmount.decimals) {
            revert AaveHelper__SwapDecimalsDoNotMatch();
        }

        DecimalNumber memory _inAmountMax = DecimalNumber({
            number: _inAsset.balanceOf(address(this)),
            decimals: _inAsset.decimals()
        });

        TransferHelper.safeApprove(address(_inAsset), address(router), _inAmountMax.number);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(_inAsset),
            tokenOut: address(_outAsset),
            fee: uint24(UNI_POOL_FEE.number / feeConverter),
            recipient: address(this),
            deadline: block.timestamp,
            amountInMaximum: _inAmountMax.number,
            amountOut: _outAmount.number,
            sqrtPriceLimitX96: 0
        });

        return router.exactOutputSingle(params);
    }

    function swapDebt(
        IERC20Metadata _oldDebtAsset,
        IERC20Metadata _newDebtAsset,
        DecimalNumber memory _paybackAmount,
        uint256 _repayRateType,
        uint256 _borrowRateType
    ) internal returns (uint256) {
        /*
         * Example flow:
         * repay usdc debt, take out eth loan, swap eth to usdc, repay flash loan.
         * Old bet asset: usdc
         * New debt asset: eth
         * Swap to asset: usdc
         *
         * Get amount of debt quoted in debt asset
         * Check that this account has enough to pay off the debt
         * Intended to be used with flash loans.
         */

        DecimalNumber memory _amountOldDebtAssetBeforeSwap = addPrecision(
            getBalanceOf(_oldDebtAsset, address(this)),
            18
        );

        DecimalNumber memory _oldDebtAssetPriceUSD = getAssetPrice(_oldDebtAsset);

        DecimalNumber memory _debtInOldDebtAsset = fixedDiv(
            getTotalDebt(address(this)),
            _oldDebtAssetPriceUSD
        );

        // Repay the old debt asset. Account is entirely paid back.
        repayDebt(
            _oldDebtAsset,
            _amountOldDebtAssetBeforeSwap,
            _oldDebtAssetPriceUSD,
            _repayRateType
        );

        /*
         * Borrow using the new debt asset.
         * Will borrow debt amount + flashloan fee + uniswap fee + trade slippage in USD
         */
        DecimalNumber memory _newLoanAmount = borrowAsset(
            _newDebtAsset,
            _oldDebtAssetPriceUSD,
            _debtInOldDebtAsset,
            _paybackAmount,
            _borrowRateType
        );

        // Swap the borrowed new debt asset back to old debt asset to repay flash loan
        return
            swapAssets(
                _newDebtAsset,
                _oldDebtAsset,
                removePrecision(_newLoanAmount, _oldDebtAsset.decimals())
            );
    }

    /* ==================================================================
                            NUMBER CONVERSION UTILS
       ================================================================== */

    function convertAaveUintToWei(DecimalNumber memory _x)
        internal
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals != 8) {
            revert AaveHelper__ConvertAAVEDecimalsDoNotMatch();
        }
        return DecimalNumber({number: _x.number * 1e10, decimals: 18});
    }

    function convertToUSDCDecimals(DecimalNumber memory _x)
        internal
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals != 18) {
            revert AaveHelper__ConvertUSDCDecimalsDoNotMatch();
        }
        return DecimalNumber({number: _x.number / 1e12, decimals: 6});
    }

    function removePrecision(DecimalNumber memory _x, uint256 _convertTo)
        internal
        view
        returns (DecimalNumber memory)
    {
        if (_x.decimals == _convertTo) {
            return _x;
        }

        if (_x.decimals != 18) {
            revert AaveHelper__AssetMustHave18Decimals();
        }

        if (_convertTo > 18 || _convertTo < 1) {
            revert AaveHelper__ConversionOutsideBounds();
        }

        console.log("CONVERT: %s, %s, %s", _x.number, _x.decimals, _convertTo);

        uint256 _removeDecimals = _x.decimals - _convertTo;
        console.log("REMOVEDEC %s", _removeDecimals);

        uint256 _newNumber = _x.number / (10**_removeDecimals);
        console.log("NEWNUM %s", _newNumber);

        return DecimalNumber({number: _newNumber, decimals: _convertTo});
    }

    function addPrecision(DecimalNumber memory _x, uint256 _convertTo)
        internal
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals == _convertTo) {
            return _x;
        }

        if (_convertTo > 18 || _convertTo < _x.decimals) {
            revert AaveHelper__ConversionOutsideBounds();
        }

        uint256 _addDecimals = _convertTo - _x.decimals;
        uint256 _newNumber = _x.number * (10**_addDecimals);
        return DecimalNumber({number: _newNumber, decimals: _convertTo});
    }

    /*  ==================================================================
                                AAVE UTILS
        ================================================================== */

    function getAssetPrice(IERC20Metadata _asset) internal view returns (DecimalNumber memory) {
        DecimalNumber memory _aavePrice = DecimalNumber({
            number: oracle.getAssetPrice(address(_asset)),
            decimals: 8
        });
        DecimalNumber memory _weiPrice = convertAaveUintToWei(_aavePrice);
        return _weiPrice;
    }

    function getTotalDebt(address _account) internal view returns (DecimalNumber memory) {
        (, uint256 _debtAmount, , , , ) = pool.getUserAccountData(_account);

        return convertAaveUintToWei(DecimalNumber({number: _debtAmount, decimals: 8}));
    }

    function getUserDetails(address _account)
        internal
        view
        returns (
            DecimalNumber memory,
            DecimalNumber memory,
            DecimalNumber memory,
            DecimalNumber memory,
            DecimalNumber memory,
            DecimalNumber memory
        )
    {
        (
            uint256 _depo,
            uint256 _debt,
            uint256 _availBorrows,
            uint256 _clt,
            uint256 _ltv,
            uint256 _health
        ) = pool.getUserAccountData(_account);

        DecimalNumber memory _deposits = convertAaveUintToWei(
            DecimalNumber({number: _depo, decimals: 8})
        );
        DecimalNumber memory _totalDebt = convertAaveUintToWei(
            DecimalNumber({number: _debt, decimals: 8})
        );
        DecimalNumber memory _availableBorrows = convertAaveUintToWei(
            DecimalNumber({number: _availBorrows, decimals: 8})
        );
        DecimalNumber memory _currLiqThresh = addPrecision(
            DecimalNumber({number: _clt, decimals: 2}),
            18
        );
        DecimalNumber memory _loanToValue = addPrecision(
            DecimalNumber({number: _ltv, decimals: 2}),
            18
        );
        DecimalNumber memory _healthFactor = DecimalNumber({number: _health, decimals: 18});

        return (
            _deposits,
            _totalDebt,
            _availableBorrows,
            _currLiqThresh,
            _loanToValue,
            _healthFactor
        );
    }

    // TODO: This should return a standardized 18 decimals...
    function getBalanceOf(IERC20Metadata _token, address _x)
        internal
        view
        returns (DecimalNumber memory)
    {
        return DecimalNumber({number: _token.balanceOf(_x), decimals: _token.decimals()});
    }

    /* ==================================================================
                                MATH FUNCTIONS
       ================================================================== */

    function fixedDiv(DecimalNumber memory _x, DecimalNumber memory _y)
        internal
        view
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__DivDecimalsDoNotMatch();
        }
        console.log("DIV: %s, %s", _x.number, _y.number);
        uint256 _scalar = 10**_x.decimals;
        uint256 _result = SafeMath.div(SafeMath.mul(_x.number, _scalar), _y.number);
        return DecimalNumber({number: _result, decimals: _x.decimals});
    }

    function fixedMul(DecimalNumber memory _x, DecimalNumber memory _y)
        internal
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__MulDecimalsDoNotMatch();
        }

        uint256 _denominator = 10**_x.decimals;
        uint256 _result = Math.mulDiv(_x.number, _y.number, _denominator);
        return DecimalNumber({number: _result, decimals: _x.decimals});
    }

    function fixedSub(DecimalNumber memory _x, DecimalNumber memory _y)
        internal
        view
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__SubDecimalsDoNotMatch();
        }
        console.log("SUB: %s, %s", _x.number, _y.number);
        uint256 _result = _x.number - _y.number;
        return DecimalNumber({number: _result, decimals: _x.decimals});
    }

    function fixedAdd(DecimalNumber memory _x, DecimalNumber memory _y)
        internal
        view
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__AddDecimalsDoNotMatch();
        }
        console.log("ADD: %s, %s", _x.number, _y.number);
        uint256 _result = _x.number + _y.number;
        return DecimalNumber({number: _result, decimals: _x.decimals});
    }
}
