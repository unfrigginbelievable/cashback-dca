pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPoolAddressesProvider.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "aave/contracts/protocol/libraries/types/DataTypes.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "src/AaveHelper.sol";

contract AaveHelperTest is Test, AaveHelper {
    IERC20Metadata public weth;
    IERC20Metadata public usdc;
    uint256 public wethAmount = 1 ether;

    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
        IPoolAddressesProvider pap = IPoolAddressesProvider(
            0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
        );

        pool = IPool(pap.getPool());
        oracle = IPriceOracle(pap.getPriceOracle());
        router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    }

    function test_convertAAVEUnitToWei() public {
        DecimalNumber memory _aaveWethPrice = DecimalNumber({number: 1650 * 1e8, decimals: 8});
        DecimalNumber memory _result = convertAaveUintToWei(_aaveWethPrice);

        assertEq(_result.number, 1650 ether);
        assertEq(_result.decimals, 18);
    }

    function test_balanceOf() public {
        vm.prank(address(weth));
        weth.transfer(address(this), wethAmount);
        DecimalNumber memory _result = balanceOf(weth, address(this));

        assertEq(_result.number, wethAmount);
        assertEq(_result.decimals, weth.decimals());
    }

    function test_fixedMul() public {
        DecimalNumber memory _x = DecimalNumber({number: 10000000000000000000, decimals: 18});
        DecimalNumber memory _y = DecimalNumber({number: 2000000000000000000, decimals: 18});
        DecimalNumber memory _result = fixedMul(_x, _y);

        assertEq(_result.number, 20000000000000000000, "Fixed-Point multiplication failed");
        assertEq(_result.decimals, 18, "Fixed-Point multiplication failed");

        DecimalNumber memory _a = DecimalNumber({number: 10000000, decimals: 6});
        DecimalNumber memory _b = DecimalNumber({number: 300000, decimals: 6});
        _result = fixedMul(_a, _b);

        assertEq(_result.number, 3000000, "Fixed-Point multiplication failed");
        assertEq(_result.decimals, 6, "Fixed-Point multiplication failed");
    }

    function test_fixedDiv() public {
        DecimalNumber memory _x = DecimalNumber({number: 10000000000000000000, decimals: 18});
        DecimalNumber memory _y = DecimalNumber({number: 20000000000000000000, decimals: 18});
        DecimalNumber memory _result = fixedDiv(_x, _y);

        assertEq(_result.number, 500000000000000000, "Fixed-Point division failed");
        assertEq(_result.decimals, 18, "Fixed-Point division failed");

        DecimalNumber memory _a = DecimalNumber({number: 10000000, decimals: 6});
        DecimalNumber memory _b = DecimalNumber({number: 50000000, decimals: 6});
        _result = fixedDiv(_a, _b);

        assertEq(_result.number, 200000, "Fixed-Point division failed");
        assertEq(_result.decimals, 6, "Fixed-Point division failed");
    }

    function test_fixedSub() public {
        DecimalNumber memory _y = DecimalNumber({number: 10000000000000000000, decimals: 18});
        DecimalNumber memory _x = DecimalNumber({number: 20000000000000000000, decimals: 18});
        DecimalNumber memory _result = fixedSub(_x, _y);

        assertEq(_result.number, 10000000000000000000, "Fixed-Point subtraction failed");
        assertEq(_result.decimals, 18, "Fixed-Point subtraction failed");

        DecimalNumber memory _b = DecimalNumber({number: 10000000, decimals: 6});
        DecimalNumber memory _a = DecimalNumber({number: 50000000, decimals: 6});
        _result = fixedSub(_a, _b);

        assertEq(_result.number, 40000000, "Fixed-Point subtraction failed");
        assertEq(_result.decimals, 6, "Fixed-Point subtraction failed");
    }

    function test_swap() public {
        vm.prank(address(weth));
        weth.transfer(address(this), 2 ether);

        DecimalNumber memory _poolFeeUSDCUnits = convertToUSDCDecimals(uniPoolFee);

        DecimalNumber memory _wethBeforeSwap = convertToUSDCDecimals(
            balanceOf(weth, address(this))
        );
        DecimalNumber memory _wethPriceUSD = getAssetPrice(address(weth));
        DecimalNumber memory _usdcPrice = getAssetPrice(address(usdc));
        DecimalNumber memory _wethPriceUSDC = convertToUSDCDecimals(
            fixedDiv(_wethPriceUSD, _usdcPrice)
        );
        DecimalNumber memory _amountUSDC = fixedMul(_wethBeforeSwap, _wethPriceUSDC);
        DecimalNumber memory _uniFeeUSDC = fixedMul(_poolFeeUSDCUnits, _wethPriceUSDC);
        DecimalNumber memory _expectedBackUSDC = fixedDiv(_amountUSDC, _usdcPrice);

        console.log("ETH to be traded %s", _wethBeforeSwap.number);
        console.log("USDC/USD price %s", _usdcPrice.number);
        console.log("ETH/USDC price: %s", _wethPriceUSDC.number);
        console.log("Trading this in usdc %s", _amountUSDC.number);
        // console.log("Uni fee eth %s", _uniFeeETH.number);
        console.log("Uni fee usdc %s", _uniFeeUSDC.number);
        // console.log("Amount usd we should get %s", _expectedBackUSD.number);
        console.log("Amount usdc we should get %s", _expectedBackUSDC.number);

        swapDebt(weth, usdc, _expectedBackUSDC, pool);

        console.log("USDC After swap: %s", usdc.balanceOf(address(this)));

        assertLt(weth.balanceOf(address(this)), _wethBeforeSwap.number);
    }
}
