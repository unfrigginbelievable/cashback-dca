// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/Interfaces/IPool.sol";
import "src/Interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "src/Libraries/DataTypes.sol";

import "src/AaveBot.sol";

contract ContractTest is Test {
    AaveBot bot;
    IERC20 weth;
    IERC20 usdc;
    IPool pool;
    IPriceOracle oracle;
    uint256 wethAmount = 1 ether;

    string ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

        bot = new AaveBot(
            0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb,
            address(weth),
            address(usdc)
        );

        pool = IPool(bot.pool());
        oracle = IPriceOracle(bot.oracle());
    }

    function testDepositToAave() public {
        uint256 _ethPrice = oracle.getAssetPrice(address(weth));

        console.log("Price of eth %s", _ethPrice);

        console.log(
            "Price of eth in contract %s",
            PRBMathUD60x18.mul(_ethPrice, wethAmount)
        );

        // Simulate eth deposit to bot
        vm.prank(address(weth));
        weth.transfer(address(bot), wethAmount);
        uint256 _transferredWethAmount = weth.balanceOf(address(bot));
        assertEq(_transferredWethAmount, wethAmount);

        // AAVE USES 8 DECIMALS NOW (IDK WHY)
        // ALL RESERVES ARE QUOTED IN USD (IDK WHY)
        bot.main();

        (
            uint256 _totalCollateral,
            uint256 _totalDebt,
            uint256 _availableBorrows,
            ,
            ,
            uint256 _health
        ) = pool.getUserAccountData(address(bot));

        assertEq(bot.depositsInEth(), wethAmount);
        assertEq(usdc.balanceOf(address(bot)), 1237260000);
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
