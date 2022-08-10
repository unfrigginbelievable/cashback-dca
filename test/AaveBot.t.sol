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
    // IPool public pool;
    // IPriceOracle public oracle;
    AggregatorV3Interface public chainlink;
    uint256 public wethAmount = 1 ether;

    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

        chainlink = AggregatorV3Interface(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);

        bot = new AaveBot(
            0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb,
            address(weth),
            address(usdc),
            0xE592427A0AEce92De3Edee1F18E0157C05861564,
            "aavebot_shares",
            "ABS"
        );

        pool = IPool(bot.pool());
        oracle = IPriceOracle(bot.oracle());
    }

    function test_Constructor() public {}

    // TODO: Test multiple depositors
    function test_deposit() public {
        address(weth).call{value: wethAmount}("");

        DecimalNumber memory _wethPriceUSD = getAssetPrice(weth);
        DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);

        uint256 _wethPriceUSDC = PRBMathUD60x18.div(_wethPriceUSD.number, _usdcPriceUSD.number);
        uint256 _borrowAmountUSDC = PRBMathUD60x18.mul(
            PRBMathUD60x18.mul(_wethPriceUSDC, wethAmount),
            7500 * (1e14)
        ) / 1e12;

        weth.approve(address(bot), wethAmount);
        bot.deposit(wethAmount, address(this));

        uint256 _howMuchBorrowed = usdc.balanceOf(address(this));

        assertEq(_borrowAmountUSDC, _howMuchBorrowed);
    }

    function test_lowHealth() public {
        test_deposit();

        console.log("===================start lowhealth==========================");

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // TODO: How low of a health value can we still borrow at?
        // push borrows past the low health threshold
        // vm.prank(address(bot));
        // pool.borrow(address(usdc), 80000000, 1, 0, address(bot));

        (uint256 _collat, uint256 _debt, , , , uint256 health) = pool.getUserAccountData(
            address(bot)
        );
        console.log("Health: %s", health);

        DecimalNumber memory _totalCollateralUSD = DecimalNumber({
            number: _collat * 1e10,
            decimals: 18
        });
        DecimalNumber memory _totalDebtUSD = DecimalNumber({
            number: (_debt + 100000000) * 1e10,
            decimals: 18
        });
        DecimalNumber memory _totalCollateralUSDC = fixedDiv(
            _totalCollateralUSD,
            getAssetPrice(usdc)
        );
        DecimalNumber memory _totalDebtUSDC = fixedDiv(_totalDebtUSD, getAssetPrice(usdc));
        DecimalNumber memory _premium = fixedMul(
            _totalDebtUSDC,
            DecimalNumber({number: 0.0009 ether, decimals: 18})
        );

        // We need to give our contract slightly more than the amount of debt so it can be paid back.
        // Simulates a flash loan
        vm.prank(address(usdc));
        usdc.transfer(address(bot), removePrecision(_totalDebtUSDC, 6).number);

        bot.executeOperation(
            address(usdc),
            removePrecision(_totalDebtUSDC, 6).number,
            removePrecision(_premium, 6).number,
            address(bot),
            ""
        );

        DecimalNumber memory _expectedUSDCAmount = removePrecision(
            fixedAdd(_totalDebtUSD, _premium),
            6
        );
        DecimalNumber memory _endingUSDCAmount = getBalanceOf(usdc, address(bot));

        assertGe(_endingUSDCAmount.number, _expectedUSDCAmount.number);
    }

    // function testDepositToAave() public {
    //     uint256 _ethPrice = oracle.getAssetPrice(address(weth));

    //     console.log("Price of eth %s", _ethPrice);

    //     console.log(
    //         "Price of eth in contract %s",
    //         PRBMathUD60x18.mul(_ethPrice, wethAmount)
    //     );

    //     // Eth deposit to bot
    //     vm.prank(address(weth));
    //     weth.transfer(address(this), wethAmount);
    //     uint256 _transferredWethAmount = weth.balanceOf(address(this));
    //     assertEq(_transferredWethAmount, wethAmount, "Weth transfer failed");

    //     // AAVE USES 8 DECIMALS NOW (IDK WHY)
    //     // ALL RESERVES ARE QUOTED IN USD (IDK WHY)

    //     console.log("Test contract addr %s", address(this));
    //     weth.approve(address(bot), wethAmount);
    //     bot.deposit(wethAmount, address(this));

    //     assertEq(
    //         bot.balanceOf(address(this)),
    //         wethAmount,
    //         "Vault did not mint correct amount of shares"
    //     );

    //     (
    //         uint256 _totalCollateral,
    //         uint256 _totalDebt,
    //         uint256 _availableBorrows,
    //         ,
    //         ,
    //         uint256 _health
    //     ) = pool.getUserAccountData(address(bot));

    //     assertEq(
    //         bot.depositors(0),
    //         address(this),
    //         "User was not added to depositors list"
    //     );

    //     uint256 _expectedBorrowedUSDC = bot.calcNewLoan(
    //         _totalCollateral,
    //         bot.MAX_BORROW() * 10e13
    //     );

    //     // Determine how much USDC was owed before payout
    //     uint256 _totalOwedUsdc = PRBMathUD60x18.mul(
    //         wethAmount,
    //         oracle.getAssetPrice(address(weth))
    //     ) + _expectedBorrowedUSDC;

    //     assertApproxEqRel(
    //         bot.usdcAmountOwed(address(this)) + _expectedBorrowedUSDC,
    //         _totalOwedUsdc,
    //         0.005 ether,
    //         "Owed USDC was not calculated properly"
    //     );

    //     assertEq(
    //         bot.depositsInEth(),
    //         wethAmount,
    //         "Deposited eth does not match"
    //     );

    //     assertApproxEqRel(
    //         usdc.balanceOf(address(this)) * 100,
    //         _expectedBorrowedUSDC,
    //         0.0001 ether,
    //         "Borrowed USDC does not match amount sent back to this depositor"
    //     );
    // }

    // function test_ExtractReserveMap() public {
    //     (uint256 loan, uint256 thresh) = bot.getLoanThresholds(address(weth));

    //     console.log("LTV: %s, LIQ: %s", loan, thresh);

    //     assertEq(loan, 8000);
    //     assertEq(thresh, 8250);
    // }

    // function test_calcNewLoan() public {
    //     uint256 result = bot.calcNewLoan(bot.depositsInEth(), 80 ether);

    //     assertEq(result, PRBMathUD60x18.mul(bot.depositsInEth(), 80 ether));
    // }

    // function test_BotRepay() public {
    //     // Do I manipulate price at aave oracle or chain link oracle?
    //     // Aave pulls directly from chainlink so prob chainlink
    //     // Maybe I can use vm.mockCall to change chainlink lastRoundData()?
    //     // Maybe I can deploy a mock chainlink interface, use prank to set aave oracle to use my fake oracle?
    //     vm.mockCall(
    //         address(chainlink),
    //         abi.encodeWithSelector(chainlink.latestRoundData.selector),
    //         abi.encode(0, 150000000000, block.timestamp, block.timestamp, 0)
    //     );

    //     // (, int256 result, , , ) = chainlink.latestRoundData();
    //     uint256 result = oracle.getAssetPrice(address(weth));

    //     assertEq(result, uint256(150000000000));
    // }
}
