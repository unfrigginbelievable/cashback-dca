pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/BridgedERC20.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "test/TestUtils.sol";

/**
 * @dev this contract is used to simulate uniswap pool swaps
 * @dev "trades" will be executed at the swap rate that is settable
 */
contract MockSwapRouter is Test, TestUtils {
    uint256 public swapRate = 160000;
    uint256 public decimals = 2;
    mapping(address => address) public minterAccount;

    constructor() {
        // I really apologize for this lol
        minterAccount[address(usdc)] = 0x096760F208390250649E3e8763348E783AEF5562;
        console.log("MockSwap %s", address(weth));
    }

    function setSwapRate(uint256 _swapRate, uint256 _decimals) external {
        swapRate = _swapRate;
        decimals = _decimals;
    }

    function spoofMint(
        BridgedERC20 _asset,
        address _account,
        uint256 _amount
    ) internal {
        console.log("Spoof asset %s", address(_asset));
        console.log("WETH adress %s", address(weth));
        if (address(_asset) == address(weth)) {
            console.log("DEALING WETH");
            vm.deal(address(this), address(this).balance + _amount);
            address(weth).call{value: _amount}("");
        } else {
            vm.prank(minterAccount[address(_asset)]);
            _asset.bridgeMint(_account, _amount);
        }
    }

    /**
     * @dev reset price before swaps
     */
    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256)
    {
        console.log("Where da weth go? %s", address(weth));
        BridgedERC20 _inToken = BridgedERC20(params.tokenIn);
        BridgedERC20 _outToken = BridgedERC20(params.tokenOut);

        // normalize all inputs to 18 decimal fixed point floats
        uint256 _fixedFee = uint256(params.fee) * 1e12;
        console.log(_fixedFee);
        uint256 _price = swapRate * (10**(18 - decimals));
        console.log(swapRate);
        uint256 _inAmount = params.amountIn * (10**(18 - _inToken.decimals()));
        console.log(_inAmount);
        uint256 _outAmountMin = params.amountOutMinimum * (10**(18 - _outToken.decimals()));
        console.log(_outAmountMin);

        // AmountIn - fee
        uint256 _amountBeforeFee = PRBMathUD60x18.mul(_inAmount, _price);
        uint256 _amountOut = _amountBeforeFee - PRBMathUD60x18.mul(_amountBeforeFee, _fixedFee);

        console.log(_amountOut);

        require(_amountOut >= _outAmountMin, "STF");

        require(
            _inToken.transferFrom(msg.sender, address(this), params.amountIn),
            "Transfer failed"
        );

        // vm.prank(minterAccount[address(_outToken)]);
        // _outToken.bridgeMint(params.recipient, params.amountOutMinimum);
        spoofMint(_outToken, params.recipient, params.amountOutMinimum);
        _outToken.transfer(msg.sender, params.amountOutMinimum);
    }
}
