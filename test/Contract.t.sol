// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/Interfaces/IPool.sol";
import "src/Interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

import "src/AaveBot.sol";

contract ContractTest is Test {
    AaveBot bot;
    IERC20 weth;
    IPool pool;
    IPriceOracle oracle;

    string ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");

    function setUp() public {
        vm.chainId(31337);

        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        weth = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        bot = new AaveBot(
            0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb,
            address(weth)
        );

        pool = IPool(bot.pool());
        oracle = IPriceOracle(bot.oracle());
    }

    function testDepositToAave() public {
        uint256 _wethAmount = 0.8 ether;
        uint256 _ethPrice = oracle.getAssetPrice(address(weth));

        console.log("Price of eth %s", _ethPrice);

        console.log(
            "Price of eth in contract %s",
            PRBMathUD60x18.mul(_ethPrice, _wethAmount)
        );

        // Simulate existing 1 eth deposit to bot
        vm.prank(address(weth));
        weth.transfer(address(bot), _wethAmount);
        uint256 _transferredWethAmount = weth.balanceOf(address(bot));
        assertEq(_transferredWethAmount, _wethAmount);

        // AAVE USES 8 DECIMALS NOW (IDK WHY)
        // ALL RESERVES ARE QUOTED IN USD (IDK WHY)
        bot.main();

        assertEq(bot.reservesInEth(), _wethAmount);
    }
}
