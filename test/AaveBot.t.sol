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

    function test_Constructor() public {
        assertEq(uint256(bot.debtStatus()), 0);
    }

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

        assertEq(bot.depositors(0), address(this));
        assertEq(_borrowAmountUSDC, _howMuchBorrowed);
    }

    function test_lowHealth() public {
        test_deposit();

        // Get bot health very low
        vm.prank(address(bot));
        pool.borrow(address(usdc), 64000000, 1, 0, address(bot));

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        bot.main();

        assertEq(uint256(bot.debtStatus()), 1);
    }

    function test_RepayWethDebt() public {
        // get bot into low health state
        test_lowHealth();
        assertEq(uint256(bot.debtStatus()), 1);

        // AAVE does not allow borrow and repay in same block
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // deposit enough weth to get bot back above low health thresh
        address(weth).call{value: wethAmount}("");
        weth.approve(address(bot), wethAmount);
        bot.deposit(wethAmount, address(this));

        //assert health is up AND debt is usdc again
        (uint256 _collat, uint256 _debt, , , , uint256 health) = pool.getUserAccountData(
            address(bot)
        );

        assertGt(health, bot.LOW_HEALTH_THRESHOLD());
        assertEq(uint256(bot.debtStatus()), 0);
    }

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
}
