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
    IERC20Metadata public dai;
    IPoolAddressesProvider public pap;
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

        pool = IPool(pap.getPool());
        oracle = IPriceOracle(pap.getPriceOracle());
        router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    }

    function test_calculateSwapOutAmount() public {
        DecimalNumber memory _inAmount = DecimalNumber({number: wethAmount, decimals: 18});
        DecimalNumber memory _tradeFee = DecimalNumber({number: 0.1 ether, decimals: 18});
        DecimalNumber memory _maxSlippage = DecimalNumber({number: 0.1 ether, decimals: 18});
        DecimalNumber memory _expectedResult = convertPriceDenomination(
            weth,
            usdc,
            fixedSub(
                _inAmount,
                fixedAdd(fixedMul(_inAmount, _tradeFee), fixedMul(_inAmount, _maxSlippage))
            )
        );
        DecimalNumber memory _result = calculateSwapOutAmount(
            weth,
            usdc,
            _inAmount,
            _tradeFee,
            _maxSlippage
        );

        assertEq(_result.number, _expectedResult.number);
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
        borrowAssetDAI();
        borrowAssetUSDC();
        borrowAssetWETH();
    }

    function borrowAssetDAI() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory _daiPrice = getAssetPrice(dai);
        DecimalNumber memory _wethPrice = getAssetPrice(weth);

        weth.approve(address(pool), wethAmount);
        pool.supply(address(weth), wethAmount, address(this), 0);
        DecimalNumber memory _borrowAmountWETH = DecimalNumber({
            number: wethAmount / 2,
            decimals: 18
        });

        borrowAsset(dai, _wethPrice, _borrowAmountWETH, 1);

        DecimalNumber memory _expectedBorrowedDAI = fixedDiv(
            fixedMul(_wethPrice, _borrowAmountWETH),
            _daiPrice
        );

        assertGt(
            dai.balanceOf(address(this)),
            truncate(_expectedBorrowedDAI, dai.decimals()).number
        );
    }

    function borrowAssetUSDC() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory _usdcPrice = getAssetPrice(usdc);
        DecimalNumber memory _wethPrice = getAssetPrice(weth);

        weth.approve(address(pool), wethAmount);
        pool.supply(address(weth), wethAmount, address(this), 0);
        DecimalNumber memory _borrowAmountWETH = DecimalNumber({
            number: wethAmount / 2,
            decimals: 18
        });

        borrowAsset(usdc, _wethPrice, _borrowAmountWETH, 1);

        DecimalNumber memory _expectedBorrowedUSDC = fixedDiv(
            fixedMul(_wethPrice, _borrowAmountWETH),
            _usdcPrice
        );

        assertGt(
            usdc.balanceOf(address(this)),
            truncate(_expectedBorrowedUSDC, usdc.decimals()).number
        );
    }

    function borrowAssetWETH() public {
        address(weth).call{value: wethAmount}("");

        uint256 _borrowAmountWETH = wethAmount / 2;

        DecimalNumber memory _usdcPrice = getAssetPrice(usdc);
        DecimalNumber memory _wethPrice = getAssetPrice(weth);

        // Get the amount of USDC that represents half of wethAmount
        DecimalNumber memory _borrowAmountUSDC = fixedDiv(
            fixedMul(_wethPrice, DecimalNumber({number: _borrowAmountWETH, decimals: 18})),
            _usdcPrice
        );

        weth.approve(address(pool), wethAmount);
        pool.supply(address(weth), wethAmount, address(this), 0);

        borrowAsset(weth, _usdcPrice, _borrowAmountUSDC, 2);

        assertGt(weth.balanceOf(address(this)), wethAmount / 2);
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

    function test_swapAssetsExactOutput() public {
        address(weth).call{value: wethAmount}("");

        uint256 wethAmountBeforeSwap = weth.balanceOf(address(this));
        DecimalNumber memory _minBack = DecimalNumber({number: 1000000, decimals: 6});

        swapAssetsExactOutput(weth, usdc, _minBack);

        assertEq(usdc.balanceOf(address(this)), _minBack.number);
        assertLt(weth.balanceOf(address(this)), wethAmountBeforeSwap);
    }

    function test_swapAssetsExactInput() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory wethAmountBeforeSwap = DecimalNumber({
            number: weth.balanceOf(address(this)),
            decimals: 18
        });

        DecimalNumber memory _minBack = truncate(
            calculateSwapOutAmount(weth, usdc, wethAmountBeforeSwap, UNI_POOL_FEE, MAX_SLIPPAGE),
            6
        );

        swapAssetsExactInput(weth, usdc, _minBack);

        assertGe(usdc.balanceOf(address(this)), _minBack.number);
        assertEq(weth.balanceOf(address(this)), 0);
    }

    function test_swapDebt() public {
        address(weth).call{value: wethAmount * 2}("");

        DecimalNumber memory _loanAmount = DecimalNumber({number: 1300000000, decimals: 6});
        DecimalNumber memory _paybackAmount = DecimalNumber({
            number: _loanAmount.number + 2,
            decimals: 6
        });

        weth.approve(address(pool), wethAmount);
        pool.supply(address(weth), wethAmount, address(this), 0);

        // Borrow USDC to get health below debt swap threshold
        // Simulates flashloan. Initial loan amount + interest
        pool.borrow(address(usdc), _loanAmount.number, 1, 0, address(this));
        // Only get enough usdc to cover the current debt
        swapAssetsExactOutput(
            weth,
            usdc,
            DecimalNumber({
                number: _paybackAmount.number - usdc.balanceOf(address(this)),
                decimals: 6
            })
        );

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Swap debt from usdc -> weth. Get back USDC to pay back flash loan.
        swapDebt(usdc, weth, addPrecision(_paybackAmount, 18), 1, 2);
        uint256 _endingUSDCBal = usdc.balanceOf(address(this));

        assertGe(_endingUSDCBal, _paybackAmount.number);
        assertApproxEqRel(_endingUSDCBal, _paybackAmount.number, 0.0001 ether);
    }
}
