// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/Interfaces/IPool.sol";
import "src/Interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "src/Libraries/DataTypes.sol";

import "src/AaveBot.sol";

contract ContractTest is Test {
    AaveBot public bot;
    IERC20 public weth;
    IERC20 public usdc;
    IPool public pool;
    IPriceOracle public oracle;
    uint256 public wethAmount = 1 ether;

    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

        bot = new AaveBot(
            0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb,
            address(weth),
            address(usdc),
            "aavebot_shares",
            "ABS"
        );

        pool = IPool(bot.pool());
        oracle = IPriceOracle(bot.oracle());
    }

    function test_Constructor() public {
        assertEq(bot.asset(), address(weth));
    }

    function testDepositToAave() public {
        uint256 _ethPrice = oracle.getAssetPrice(address(weth));

        console.log("Price of eth %s", _ethPrice);

        console.log(
            "Price of eth in contract %s",
            PRBMathUD60x18.mul(_ethPrice, wethAmount)
        );

        // Eth deposit to bot
        vm.prank(address(weth));
        weth.transfer(address(this), wethAmount);
        uint256 _transferredWethAmount = weth.balanceOf(address(this));
        assertEq(_transferredWethAmount, wethAmount, "Weth transfer failed");

        // AAVE USES 8 DECIMALS NOW (IDK WHY)
        // ALL RESERVES ARE QUOTED IN USD (IDK WHY)

        console.log("Test contract addr %s", address(this));
        weth.approve(address(bot), wethAmount);
        bot.deposit(wethAmount);

        assertEq(
            bot.balanceOf(address(this)),
            wethAmount,
            "Vault did not mint correct amount of shares"
        );

        (
            uint256 _totalCollateral,
            uint256 _totalDebt,
            uint256 _availableBorrows,
            ,
            ,
            uint256 _health
        ) = pool.getUserAccountData(address(bot));

        assertEq(
            bot.depositors(0),
            address(this),
            "User was not added to depositors list"
        );

        uint256 _expectedBorrowedUSDC = bot.calcNewLoan(
            _totalCollateral,
            bot.MAX_BORROW() * 10e13
        );

        // Determine how much USDC was owed before payout
        uint256 _totalOwedUsdc = PRBMathUD60x18.mul(
            wethAmount,
            oracle.getAssetPrice(address(weth))
        ) + _expectedBorrowedUSDC;

        assertApproxEqRel(
            bot.usdcAmountOwed(address(this)) + _expectedBorrowedUSDC,
            _totalOwedUsdc,
            0.005 ether,
            "Owed USDC was not calculated properly"
        );

        assertEq(
            bot.depositsInEth(),
            wethAmount,
            "Deposited eth does not match"
        );

        assertApproxEqRel(
            usdc.balanceOf(address(this)) * 100,
            _expectedBorrowedUSDC,
            0.0001 ether,
            "Borrowed USDC does not match amount sent back to this depositor"
        );
    }

    function test_ExtractReserveMap() public {
        (uint256 loan, uint256 thresh) = bot.getLoanThresholds(address(weth));

        console.log("LTV: %s, LIQ: %s", loan, thresh);

        assertEq(loan, 8000);
        assertEq(thresh, 8250);
    }

    function test_calcNewLoan() public {
        uint256 result = bot.calcNewLoan(bot.depositsInEth(), 80 ether);

        assertEq(result, PRBMathUD60x18.mul(bot.depositsInEth(), 80 ether));
    }
}
