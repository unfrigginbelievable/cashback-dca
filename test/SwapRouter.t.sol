pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./TestUtils.sol";

contract TestMockSwapRouter is Test, TestUtils {
    function setUp() public {
        setChain();
    }

    // WETH -> USDC
    function test_mockSwap1() public {
        MockSwapRouter existingRouter = spoofUniswapRouter(300000, 2);

        mintWETH(1 ether);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: uint24(3000),
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: 1 ether,
            amountOutMinimum: 2900 * 1e6,
            sqrtPriceLimitX96: 0
        });

        weth.approve(address(router), 1 ether);
        router.exactInputSingle(params);

        assertEq(usdc.balanceOf(address(this)), 2900 * 1e6, "USDC trade failed");
    }

    // USDC -> WETH
    function test_mockSwap2() public {
        // mint 3000 usdc
        mintUSDC(address(this), 3000 * 1e6);

        console.log("Test swap %s", address(weth));

        // Inverse of 1 WETH = 3000 USDC
        MockSwapRouter existingRouter = spoofUniswapRouter(0.000333333 ether, 18);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(weth),
            fee: uint24(3000),
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: 3000 * 1e6,
            amountOutMinimum: 0.9 ether,
            sqrtPriceLimitX96: 0
        });

        console.log("Test swap 2 %s", address(existingRouter.weth()));

        usdc.approve(address(router), 3000 * 1e6);
        router.exactInputSingle(params);

        assertEq(weth.balanceOf(address(this)), 0.9 ether, "WETH trade failed");
    }
}
