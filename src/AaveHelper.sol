//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "aave/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract AaveHelper {
    uint24 uniPoolFee = 3000;
    uint24 feeDenominator = 1000000;

    function swapDebt(
        IERC20 _inAsset,
        IERC20 _outAsset,
        uint256 _outAmount,
        ISwapRouter _router,
        IPool _pool
    ) internal returns (uint256) {
        uint256 _inAmountMax = _inAsset.balanceOf(address(this));

        TransferHelper.safeApprove(address(_inAsset), address(_router), _inAmountMax);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(_inAsset),
            tokenOut: address(_outAsset),
            fee: uniPoolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountInMaximum: _inAmountMax,
            amountOut: _outAmount,
            sqrtPriceLimitX96: 0
        });

        console.log("About to swap");

        return _router.exactOutputSingle(params);
        // return 0;
    }
}
