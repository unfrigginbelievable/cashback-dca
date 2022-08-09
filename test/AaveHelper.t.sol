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
import "aave-periphery/contracts/misc/interfaces/IUiPoolDataProviderV3.sol";
import "aave-periphery/contracts/misc/interfaces/IWETHGateway.sol";
import "@solmate/tokens/WETH.sol";

import "src/AaveHelper.sol";

contract AaveHelperTest is Test, AaveHelper {
    IERC20Metadata public weth;
    IERC20Metadata public usdc;
    IERC20Metadata public usdt;
    IERC20Metadata public dai;
    IERC20Metadata public vArbWeth;
    IERC20Metadata public sArbWeth;
    IERC20Metadata public aArbWeth;
    IUiPoolDataProviderV3 public poolData;
    IPoolAddressesProvider public pap;
    IWETHGateway public wethGW;
    uint256 public wethAmount = 1 ether;

    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
        pap = IPoolAddressesProvider(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);
        dai = IERC20Metadata(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
        usdt = IERC20Metadata(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
        vArbWeth = IERC20Metadata(0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351);
        aArbWeth = IERC20Metadata(0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8);
        sArbWeth = IERC20Metadata(0xD8Ad37849950903571df17049516a5CD4cbE55F6);

        pool = IPool(pap.getPool());
        oracle = IPriceOracle(pap.getPriceOracle());
        router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        poolData = IUiPoolDataProviderV3(0x3f960bB91e85Ae2dB561BDd01B515C5A5c65802b);
        wethGW = IWETHGateway(0xC09e69E79106861dF5d289dA88349f10e2dc6b5C);
    }

    function test_convertAAVEUnitToWei() public {
        DecimalNumber memory _aaveWethPrice = DecimalNumber({number: 1650 * 1e8, decimals: 8});
        DecimalNumber memory _result = convertAaveUintToWei(_aaveWethPrice);

        assertEq(_result.number, 1650 ether);
        assertEq(_result.decimals, 18);
    }

    function test_convertToUSDCDecimals() public {
        DecimalNumber memory _result = convertToUSDCDecimals(
            DecimalNumber({number: 1 ether, decimals: 18})
        );
        assertEq(_result.number, 1 * (1e6));
        assertEq(_result.decimals, 6);
    }

    function test_getAssetPrice() public {
        uint256 _wethPrice = oracle.getAssetPrice(address(weth));
        DecimalNumber memory _result = getAssetPrice(weth);

        assertEq(_result.number, _wethPrice * (1e10));
        assertEq(_result.decimals, 18);
    }

    function test_balanceOf() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory _result = getBalanceOf(weth, address(this));

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

        _x = DecimalNumber({number: 991800000000000000, decimals: 18});
        _y = DecimalNumber({number: 1649 ether, decimals: 18});
        _result = fixedDiv(_x, _y);

        assertEq(_result.number, 601455427531837);
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

    function test_borrowAsset() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory _usdcPrice = getAssetPrice(usdc);
        DecimalNumber memory _wethPrice = getAssetPrice(weth);
        DecimalNumber memory _wethAmount = getBalanceOf(weth, address(this));

        // Get the amount of USDC that represents half of wethAmount
        DecimalNumber memory _borrowAmount = fixedDiv(
            fixedMul(_wethPrice, DecimalNumber({number: _wethAmount.number / 2, decimals: 18})),
            _usdcPrice
        );

        weth.approve(address(pool), wethAmount);
        pool.supply(address(weth), wethAmount, address(this), 0);

        borrowAsset(weth, _usdcPrice, _borrowAmount, DecimalNumber({number: 0, decimals: 18}), 2);

        assertGt(weth.balanceOf(address(this)), _wethAmount.number / 2);
    }

    function test_repayDebt() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory _wethAmount = getBalanceOf(weth, address(this));
        DecimalNumber memory _borrowAmount = DecimalNumber({
            number: _wethAmount.number / 2,
            decimals: 18
        });

        weth.approve(address(pool), _wethAmount.number);
        pool.supply(address(weth), wethAmount, address(this), 0);
        pool.borrow(address(weth), _borrowAmount.number, 2, 0, address(this));

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        DecimalNumber memory _repayAmount = DecimalNumber({
            number: _borrowAmount.number + 0.1 ether,
            decimals: 18
        });

        vm.prank(address(weth));
        weth.transfer(address(this), _repayAmount.number);

        DecimalNumber memory _amountRepaid = repayDebt(weth, _repayAmount, getAssetPrice(weth), 2);

        assertGt(_amountRepaid.number, _borrowAmount.number);
        assertEq(_amountRepaid.decimals, 18);
    }

    function test_swapAssets() public {
        address(weth).call{value: wethAmount}("");

        uint256 wethAmountBeforeSwap = weth.balanceOf(address(this));
        DecimalNumber memory _minBack = DecimalNumber({number: 1000000, decimals: 6});

        swapAssets(weth, usdc, _minBack);

        assertEq(usdc.balanceOf(address(this)), _minBack.number);
        assertLt(weth.balanceOf(address(this)), wethAmountBeforeSwap);
    }

    function test_swapDebt() public {
        address(weth).call{value: wethAmount}("");

        uint256 _borrowedUSDCAmount = 1300000000;
        DecimalNumber memory _loanAmount = DecimalNumber({
            number: _borrowedUSDCAmount,
            decimals: 6
        });

        weth.approve(address(pool), wethAmount);
        pool.supply(address(weth), wethAmount, address(this), 0);
        // 100 usdc
        pool.borrow(address(usdc), _loanAmount.number, 1, 0, address(this));

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Get some more USDC to cover interest accumulation
        address(weth).call{value: wethAmount}("");
        swapAssets(weth, usdc, _loanAmount);

        swapDebt(usdc, weth, DecimalNumber({number: 0, decimals: 18}), 1, 2);

        console.log("Borrowed USDC amount %s", _loanAmount.number);
        console.log("Ending USDC amount %s", usdc.balanceOf(address(this)));

        uint256 _endingUSDCBal = usdc.balanceOf(address(this));
        assertGt(_endingUSDCBal, _loanAmount.number);
        assertApproxEqRel(_endingUSDCBal, _loanAmount.number, 0.01 ether);
    }
}
