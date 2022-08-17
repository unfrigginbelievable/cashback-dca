//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

    function calcNewLoan(
        DecimalNumber memory _deposits,
        DecimalNumber memory _borrows,
        DecimalNumber memory _loanPercentage
    ) internal pure returns (DecimalNumber memory) {
        DecimalNumber memory _x = fixedMul(_deposits, _loanPercentage);
        if (_x.number > _borrows.number) {
            return fixedSub(_x, _borrows);
        } else {
            return DecimalNumber({number: 0, decimals: _deposits.decimals});
        }
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

    function swapAssetsExactInput(
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

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(_inAsset),
            tokenOut: address(_outAsset),
            fee: uint24(UNI_POOL_FEE.number / feeConverter),
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: _inAmountMax.number,
            amountOutMinimum: _outAmount.number,
            sqrtPriceLimitX96: 0
        });

        return router.exactInputSingle(params);
    }

    function swapAssetsExactOutput(
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
            deadline: block.timestamp + 15,
            amountInMaximum: _inAmountMax.number,
            amountOut: _outAmount.number,
            sqrtPriceLimitX96: 0
        });

        return router.exactOutputSingle(params);
    }

    /**
        @dev Does all the calculations to borrow in terms of another asset
        @dev Matches old debt amount + flashloan fee + uniswap fee + trade slippage in USD
        @param _paybackAmountInOldDebtAsset flashloan amount + flashloan premium
     */
    function borrowAsset(
        IERC20Metadata _newDebtAsset,
        DecimalNumber memory _oldDebtAssetPriceUSD,
        DecimalNumber memory _paybackAmountInOldDebtAsset,
        uint256 _borrowRateType
    ) internal returns (DecimalNumber memory) {
        // _payBackAmount + uni fee + slippage
        DecimalNumber memory _newDebtAssetPriceUSD = getAssetPrice(_newDebtAsset);

        DecimalNumber memory _paybackAmountInNewDebtAsset = fixedDiv(
            fixedMul(_oldDebtAssetPriceUSD, _paybackAmountInOldDebtAsset),
            _newDebtAssetPriceUSD
        );

        DecimalNumber memory _slippage = fixedMul(_paybackAmountInNewDebtAsset, MAX_SLIPPAGE);
        DecimalNumber memory _uniFee = fixedMul(_paybackAmountInNewDebtAsset, UNI_POOL_FEE);
        DecimalNumber memory _newLoanAmount = fixedAdd(
            _paybackAmountInNewDebtAsset,
            fixedAdd(_slippage, _uniFee)
        );

        pool.borrow(
            address(_newDebtAsset),
            truncate(_newLoanAmount, _newDebtAsset.decimals()).number,
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

    /**
     * @dev calcs how much assetOut a trade you get from an amount of assetIn
     */
    function calculateSwapOutAmount(
        IERC20Metadata _inAsset,
        IERC20Metadata _outAsset,
        DecimalNumber memory _inAssetAmount,
        DecimalNumber memory _tradeFee,
        DecimalNumber memory _maxSlippage
    ) internal view returns (DecimalNumber memory) {
        // outAmount = inAssetAmount - (_tradeFee + _maxSlippage)
        DecimalNumber memory _inAssetOut = fixedSub(
            _inAssetAmount,
            fixedAdd(fixedMul(_inAssetAmount, _tradeFee), fixedMul(_inAssetAmount, _maxSlippage))
        );
        return convertPriceDenomination(_inAsset, _outAsset, _inAssetOut);
    }

    /**
    @param _oldDebtAsset asset that debt is currently held in
    @param _newDebtAsset asset that debt should be swapped to
    @param _paybackAmountInOldDebtAsset Essentially the flashloan amount + flashloan premium
    @param _repayRateType uint that represents the interest rate of old borrow. 1=stable, 2=variable
    @param _borrowRateType uint that represents the interest rate of new borrow. 1=stable, 2=variable
    */
    function swapDebt(
        IERC20Metadata _oldDebtAsset,
        IERC20Metadata _newDebtAsset,
        DecimalNumber memory _paybackAmountInOldDebtAsset,
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
        if (_paybackAmountInOldDebtAsset.decimals != 18) {
            revert AaveHelper__AssetMustHave18Decimals();
        }

        DecimalNumber memory _amountOldDebtAssetBeforeSwap = addPrecision(
            getBalanceOf(_oldDebtAsset, address(this)),
            18
        );

        DecimalNumber memory _oldDebtAssetPriceUSD = getAssetPrice(_oldDebtAsset);
        DecimalNumber memory _newDebtAssetPriceUSD = getAssetPrice(_newDebtAsset);

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
            _paybackAmountInOldDebtAsset,
            _borrowRateType
        );

        uint256 _wethBorrowUSDCAmt = _oldDebtAsset.balanceOf(address(this));

        // Calculate how much was borrowed in terms of old asset
        DecimalNumber memory _newLoanAmountInOldDebtAsset = fixedDiv(
            fixedMul(_newDebtAssetPriceUSD, _newLoanAmount),
            _oldDebtAssetPriceUSD
        );

        // Swap the borrowed new debt asset back to old debt asset to repay flash loan

        swapAssetsExactOutput(
            _newDebtAsset,
            _oldDebtAsset,
            truncate(_paybackAmountInOldDebtAsset, _oldDebtAsset.decimals())
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

    function truncate(DecimalNumber memory _x, uint256 _convertTo)
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

        uint256 _removeDecimals = _x.decimals - _convertTo;

        uint256 _newNumber = _x.number / (10**_removeDecimals);

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
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__DivDecimalsDoNotMatch();
        }

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
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__SubDecimalsDoNotMatch();
        }

        uint256 _result = _x.number - _y.number;
        return DecimalNumber({number: _result, decimals: _x.decimals});
    }

    function fixedAdd(DecimalNumber memory _x, DecimalNumber memory _y)
        internal
        pure
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__AddDecimalsDoNotMatch();
        }

        uint256 _result = _x.number + _y.number;
        return DecimalNumber({number: _result, decimals: _x.decimals});
    }
}
