// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./TestUtils.sol";

import "aave/contracts/interfaces/IPool.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "aave/contracts/protocol/libraries/types/DataTypes.sol";

import "src/AaveBot.sol";
import "src/AaveHelper.sol";

contract AaveBotTest is TestUtils {
    AaveBot public bot;
    uint256 public wethAmount = 1 ether;

    function setUp() public {
        setChain();

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

        DecimalNumber memory _minUSDCOut = truncate(
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
         * Test amount owed <= (initial deposit * 0.25)
         * Test paid tracking = amount in this contract
         * Test deposited weth credited to this contrace = amount deposited
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
        DecimalNumber memory _borrowsUSDC = truncate(fixedDiv(_borrowsUSD, _usdcPrice), 6);

        (uint256 _borrowPercent, uint256 _borrowDecimals) = bot.MAX_BORROW();
        DecimalNumber memory _maxBorrowPercent = DecimalNumber({
            number: _borrowPercent,
            decimals: _borrowDecimals
        });

        // (usdcIn - (UNI_FEE + Slippage)) * Max Borrow Percent
        DecimalNumber memory _expectedBorrowsUSDC = truncate(
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

        DecimalNumber memory _expectedOwedPercent = DecimalNumber({
            number: 1 ether - _borrowPercent,
            decimals: 18
        });
        DecimalNumber memory _expectedOwedUSDC = truncate(
            fixedMul(addPrecision(_minUSDCOut, 18), _expectedOwedPercent),
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
        assertLe(
            _borrowsUSD.number,
            fixedMul(_depositsUSD, _maxBorrowPercent).number,
            "Borrowed more than expected"
        );
        assertGe(
            usdc.balanceOf(address(this)),
            _borrowsUSDC.number,
            "USDC balance paid out does not match expected"
        );
        assertApproxEqRel(
            bot.usdcAmountOwed(address(this)),
            _expectedOwedUSDC.number,
            0.01 ether,
            "Expected owed USDC does not match"
        );
        assertEq(
            bot.usdcAmountPaid(address(this)),
            usdc.balanceOf(address(this)),
            "Amount paid tracking does not match expected"
        );
        assertApproxEqRel(
            bot.wethAmountDeposited(address(this)),
            wethAmount,
            0.02 ether,
            "WETH credited does not match expected"
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
     * @dev tests totalAssets calculation
     */
    function test_totalAssets() public {
        uint256 _result = bot.totalAssets();
        assertEq(_result, 0);

        test_deposit();

        // (availableBorrows * 0.75) / usdcPriceUSD

        // DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);
        DecimalNumber memory _maxBorrow = DecimalNumber({number: 0.75 ether, decimals: 18});
        // (DecimalNumber memory _depositsUSD, , , , , ) = getUserDetails(address(bot));

        uint256 _totalAssetsActual = bot.totalAssets();

        // DecimalNumber memory _totalAssetsExpected = fixedDiv(
        //     fixedMul(_depositsUSD, _maxBorrow),
        //     _usdcPriceUSD
        // );

        DecimalNumber memory _totalUSDCDeposits = convertPriceDenomination(
            weth,
            usdc,
            DecimalNumber({number: wethAmount, decimals: 18})
        );
        DecimalNumber memory _totalAssetsExpected = fixedMul(_totalUSDCDeposits, _maxBorrow);
        assertApproxEqRel(
            _totalAssetsActual,
            truncate(_totalAssetsExpected, 6).number,
            0.02 ether,
            "Total assets does not match expected"
        );
    }

    function test_redeem() public {
        test_deposit();
        console.log("DEPOSIT COMPLETE");
        console.log("STARTING_REDEEM");

        uint256 _vaultShares = bot.balanceOf(address(this));

        bot.redeem(_vaultShares, address(this), address(this));

        DecimalNumber memory _minExpectedWETH = DecimalNumber({
            number: PRBMathUD60x18.mul(wethAmount, 0.75 ether),
            decimals: 18
        });
        DecimalNumber memory _maxExpectedRemainingWETH = DecimalNumber({
            number: PRBMathUD60x18.mul(wethAmount, 0.25 ether),
            decimals: 18
        });
        DecimalNumber memory _usdcBalance = addPrecision(getBalanceOf(usdc, address(this)), 18);
        DecimalNumber memory _expectedPaidUSDC = convertPriceDenomination(
            weth,
            usdc,
            _minExpectedWETH
        );
        DecimalNumber memory _expectedRemainingUSDC = convertPriceDenomination(
            weth,
            usdc,
            _maxExpectedRemainingWETH
        );
        DecimalNumber memory _actualRemainingUSDC = addPrecision(
            DecimalNumber({number: bot.usdcAmountOwed(address(this)), decimals: usdc.decimals()}),
            18
        );

        assertGe(_usdcBalance.number, _expectedPaidUSDC.number, "Expected payout does not match");
        assertApproxEqRel(
            _actualRemainingUSDC.number,
            _expectedRemainingUSDC.number,
            0.02 ether,
            "Expected remaining payout does not match"
        );
    }

    function test_payoutDepositor() public {
        test_redeem();
        console.log("REDEEM COMPLETE");
        console.log("STARTING PAYOUT");

        uint256 _amountOwed = bot.usdcAmountOwed(address(this));
        console.log("Amount USDC owed %s", _amountOwed);

        (, , , , , DecimalNumber memory _health) = getUserDetails(address(bot));
        DecimalNumber memory oldEthPrice = getAssetPrice(weth);
        int256 newEthPrice = int256((oldEthPrice.number / 1e10) * 2);
        setETHUSDPrice(newEthPrice);

        console.log("Old weth price %s", oldEthPrice.number);
        console.log("New weth price %s", getAssetPrice(weth).number);
        console.log("Old health %s", _health.number);
        (, , , , , _health) = getUserDetails(address(bot));
        console.log("New health %s", _health.number);

        // Let the price change marinate?
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // First loop will pay user out so their owed usdc is 0
        bot.main();
        console.log("Main loop 1 done");
        _amountOwed = bot.usdcAmountOwed(address(this));
        console.log("Amount USDC owed %s", _amountOwed);
        console.log("Total USDC owed %s", bot.totalUSDCOwed());

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Second loop will remove user from the bot and pay back that user's debt
        bot.main();
        console.log("Main loop 2 done");
        _amountOwed = bot.usdcAmountOwed(address(this));
        console.log("Amount USDC owed %s", _amountOwed);
    }
}
