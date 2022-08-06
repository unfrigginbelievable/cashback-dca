//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "aave/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "aave/contracts/protocol/libraries/types/DataTypes.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

error AaveHelper__ConvertUSDCDecimalsDoNotMatch();
error AaveHelper__ConvertAAVEDecimalsDoNotMatch();
error AaveHelper__SwapDecimalsDoNotMatch();
error AaveHelper__DivDecimalsDoNotMatch();
error AaveHelper__MulDecimalsDoNotMatch();
error AaveHelper__SubDecimalsDoNotMatch();
error AaveHelper__AddDecimalsDoNotMatch();

contract AaveHelper {
    struct DecimalNumber {
        uint256 number;
        uint256 decimals;
    }

    uint256 public feeConverter = 1e12;
    DecimalNumber public UNI_POOL_FEE = DecimalNumber({number: 3000 * feeConverter, decimals: 18});
    DecimalNumber public MAX_SLIPPAGE = DecimalNumber({number: 5000 * feeConverter, decimals: 18});

    IPool public pool;
    IPriceOracle public oracle;
    ISwapRouter public router;

    function swapDebt(
        IERC20Metadata _inAsset,
        IERC20Metadata _outAsset,
        DecimalNumber memory _outAmount,
        // ISwapRouter _router,
        IPool _pool
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

        console.log("About to swap");

        return router.exactOutputSingle(params);
    }

    /*
     * ==================================================================
     * ===================== NUMBER CONVERSION UTILS ====================
     * ==================================================================
     */

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

    function getAssetPrice(IERC20Metadata _asset) internal view returns (DecimalNumber memory) {
        DecimalNumber memory _aavePrice = DecimalNumber({
            number: oracle.getAssetPrice(address(_asset)),
            decimals: 8
        });
        DecimalNumber memory _weiPrice = convertAaveUintToWei(_aavePrice);
        return _weiPrice;
    }

    function balanceOf(IERC20Metadata _token, address _x)
        internal
        view
        returns (DecimalNumber memory)
    {
        return DecimalNumber({number: _token.balanceOf(_x), decimals: _token.decimals()});
    }

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
        view
        returns (DecimalNumber memory)
    {
        if (_x.decimals != _y.decimals) {
            revert AaveHelper__MulDecimalsDoNotMatch();
        }
        console.log("MUL: %s, %s", _x.number, _y.number);
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
