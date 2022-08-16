// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "aave/contracts/protocol/libraries/types/DataTypes.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "src/AaveBot.sol";
import "src/AaveHelper.sol";

contract AaveBotTest is Test, AaveHelper {
    AaveBot public bot;
    IERC20Metadata public weth;
    IERC20Metadata public usdc;
    AggregatorV3Interface public chainlink;
    uint256 public wethAmount = 1 ether;

    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
        router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        chainlink = AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);

        bot = new AaveBot(
            0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb,
            address(weth),
            address(usdc),
            address(router),
            "aavebot_shares",
            "ABS"
        );

        pool = IPool(bot.pool());
        oracle = IPriceOracle(bot.oracle());
    }

    /**
      @dev calculates how much weth and usdc out required to get _wethAmount from trade
      @dev only used for testing
     */
    function calcWethAmountToUSDCTrade(uint256 _wethAmount)
        internal
        returns (DecimalNumber memory, DecimalNumber memory)
    {
        // Fee must be added TWICE. Once for fees to swap from weth->usdc before deposit.
        // Again for fees to swap usdc->weth after deposit.
        DecimalNumber memory _feeMultiplier = fixedAdd(
            DecimalNumber({number: 1 ether, decimals: 18}),
            fixedAdd(UNI_POOL_FEE, MAX_SLIPPAGE)
        );

        DecimalNumber memory _wethAmountDec = DecimalNumber({number: _wethAmount, decimals: 18});
        DecimalNumber memory _wethInAmount = fixedMul(
            fixedAdd(
                _wethAmountDec,
                fixedAdd(
                    fixedMul(_wethAmountDec, UNI_POOL_FEE),
                    fixedMul(_wethAmountDec, MAX_SLIPPAGE)
                )
            ),
            _feeMultiplier
        );

        DecimalNumber memory _minUSDCOut = removePrecision(
            fixedMul(convertPriceDenomination(weth, usdc, _wethAmountDec), _feeMultiplier),
            6
        );

        return (_wethInAmount, _minUSDCOut);
    }

    function test_Constructor() public {
        assertEq(uint256(bot.debtStatus()), 0);
    }

    // TODO: Test multiple depositors
    function test_deposit() public {
        /*
         * Test borrowers list
         * Test vault shares sent to this contract
         * Test amount of weth deposited to aave
         * Test amount of usdc borrowed from aave
         * Test amount of usdc owed back to this contract
         * Test amount borrowed not > max borrowed percent
         */

        // Get enough WETH that we can swap for exactly 1 WETH worth of USDC
        (
            DecimalNumber memory _wethTradeAmount,
            DecimalNumber memory _minUSDCOut
        ) = calcWethAmountToUSDCTrade(wethAmount);

        address(weth).call{value: _wethTradeAmount.number}("");
        swapAssetsExactOutput(weth, usdc, _minUSDCOut);

        DecimalNumber memory _usdcPrice = getAssetPrice(usdc);
        DecimalNumber memory _wethPrice = getAssetPrice(weth);

        /// @note the swap does work correctly

        usdc.approve(address(bot), _minUSDCOut.number);
        bot.deposit(_minUSDCOut.number, address(this));

        (
            DecimalNumber memory _depositsUSD,
            DecimalNumber memory _borrowsUSD,
            ,
            ,
            ,

        ) = getUserDetails(address(bot));

        DecimalNumber memory _depositsWETH = fixedDiv(_depositsUSD, _wethPrice);
        DecimalNumber memory _borrowsUSDC = removePrecision(fixedDiv(_borrowsUSD, _usdcPrice), 6);

        (uint256 _borrowPercent, uint256 _borrowDecimals) = bot.MAX_BORROW();
        DecimalNumber memory _maxBorrowPercent = DecimalNumber({
            number: _borrowPercent,
            decimals: _borrowDecimals
        });

        // (usdcIn - (UNI_FEE + Slippage)) * Max Borrow Percent
        DecimalNumber memory _expectedBorrowsUSDC = removePrecision(
            fixedMul(
                fixedSub(
                    addPrecision(_minUSDCOut, 18),
                    fixedAdd(
                        fixedMul(addPrecision(_minUSDCOut, 18), UNI_POOL_FEE),
                        fixedMul(addPrecision(_minUSDCOut, 18), MAX_SLIPPAGE)
                    )
                ),
                _maxBorrowPercent
            ),
            6
        );

        assertEq(bot.depositors(0), address(this));
        assertEq(bot.balanceOf(address(this)), _minUSDCOut.number);
        assertGe(_depositsWETH.number, wethAmount, "WETH deposits does not match expected");
        assertGe(
            _borrowsUSDC.number,
            _expectedBorrowsUSDC.number,
            "Borrowed USDC does not match expected"
        );
        assertGe(
            usdc.balanceOf(address(this)),
            _borrowsUSDC.number,
            "USDC balance paid out does not match expected"
        );
        assertLe(
            _borrowsUSD.number,
            fixedMul(_depositsUSD, _maxBorrowPercent).number,
            "Borrowed more than expected"
        );
    }

    /**
     * @dev Ensure bot swaps debt to WETH when health below threshold
     */
    function test_lowHealth() public {
        // TODO: Ensure debt is actually represented in ETH
        test_deposit();

        // Get bot health very low
        vm.prank(address(bot));
        pool.borrow(address(usdc), 64000000, 1, 0, address(bot));

        (
            DecimalNumber memory _depositsUSD,
            DecimalNumber memory _borrowsUSD,
            ,
            ,
            ,
            DecimalNumber memory _health
        ) = getUserDetails(address(bot));

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        assertLt(_health.number, bot.LOW_HEALTH_THRESHOLD());

        bot.main();

        assertEq(uint256(bot.debtStatus()), 1);
    }

    /**
     * @dev Ensure bot ability to swap debt weth->usdc when health above threshold
     */
    function test_RepayWethDebt() public {
        // get bot into low health state
        test_lowHealth();
        assertEq(uint256(bot.debtStatus()), 1);

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // deposit enough weth to get bot back above low health thresh
        (
            DecimalNumber memory _wethTradeAmount,
            DecimalNumber memory _minUSDCOut
        ) = calcWethAmountToUSDCTrade(wethAmount);

        address(weth).call{value: _wethTradeAmount.number}("");
        swapAssetsExactOutput(weth, usdc, _minUSDCOut);
        usdc.approve(address(bot), _minUSDCOut.number);

        bot.deposit(_minUSDCOut.number, address(this));

        //assert health is up AND debt is usdc again
        (uint256 _collat, uint256 _debt, , , , uint256 health) = pool.getUserAccountData(
            address(bot)
        );

        assertGt(health, bot.LOW_HEALTH_THRESHOLD());
        assertEq(uint256(bot.debtStatus()), 0);
    }

    /**
        @dev tests the totalAssets after a borrow to the pool max limit is made
     */
    function test_TotalAssets() public {
        test_deposit();

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        uint256 _vaultShares = bot.balanceOf(address(this));

        DecimalNumber memory _wethPriceUSD = getAssetPrice(weth);
        DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);
        (uint256 depositsUSD, uint256 _borrowsUSD, uint256 _availableBorrowsUSD, , , ) = pool
            .getUserAccountData(address(bot));
        uint256 _maxBorrow = PRBMathUD60x18.mul(depositsUSD, 0.8 ether);
        uint256 _newBorrowUSD = _maxBorrow - _borrowsUSD;
        uint256 _newBorrowUSDC = PRBMathUD60x18.div(_newBorrowUSD, _usdcPriceUSD.number) / 1e2;

        vm.prank(address(bot));
        pool.borrow(address(usdc), _newBorrowUSDC, 1, 0, address(bot));

        (, , _availableBorrowsUSD, , , ) = pool.getUserAccountData(address(bot));

        // this should equal 0, or at least close
        DecimalNumber memory _availableWETH = DecimalNumber({
            number: bot.convertToAssets(_vaultShares),
            decimals: 18
        });

        uint256 _resultUSD = removePrecision(fixedMul(_availableWETH, _wethPriceUSD), 8).number;

        assertApproxEqRel(_resultUSD, _availableBorrowsUSD, 0.034 ether);
    }

    /**
        @dev tests the totalAssets after a standard deposit
     */
    function test_TotalAssets2() public {
        test_deposit();

        uint256 _vaultShares = bot.balanceOf(address(this));
        DecimalNumber memory _wethPriceUSD = getAssetPrice(weth);
        (, , uint256 _availableBorrowsUSD, , , ) = pool.getUserAccountData(address(bot));

        DecimalNumber memory _availableWETH = DecimalNumber({
            number: bot.convertToAssets(_vaultShares),
            decimals: 18
        });
        uint256 _result = removePrecision(fixedMul(_availableWETH, _wethPriceUSD), 8).number;

        assertApproxEqRel(_availableBorrowsUSD, _result, 0.0001 ether);
    }

    function test_totalAssets3() public {
        uint256 _result = bot.totalAssets();
        assertEq(_result, 0);
        test_deposit();
    }

    function test_redeem() public {
        test_deposit();

        uint256 _vaultShares = bot.balanceOf(address(this));

        bot.redeem(_vaultShares, address(this), address(this));

        (, , uint256 _availableBorrowsUSD, , , uint256 _health) = pool.getUserAccountData(
            address(bot)
        );

        uint256 _minExpectedWETH = PRBMathUD60x18.mul(wethAmount, 0.8 ether);
        DecimalNumber memory _usdcBalance = addPrecision(getBalanceOf(usdc, address(this)), 18);
        DecimalNumber memory _usdcAsWETH = convertPriceDenomination(usdc, weth, _usdcBalance);
        uint256 result = weth.balanceOf(address(this)) + _usdcAsWETH.number;

        assertApproxEqRel(
            weth.balanceOf(address(this)) + _usdcAsWETH.number,
            _minExpectedWETH,
            0.001 ether
        );

        assertEq(bot.usdcAmountOwed(address(this)), 0);

        console.log(_health);

        bot.main();

        console.log(uint256(bot.debtStatus()));
    }
}
