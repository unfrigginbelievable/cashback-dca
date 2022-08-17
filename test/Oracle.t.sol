pragma solidity ^0.8.0;

import "./TestUtils.sol";
import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../src/mocks/MockAggregator.sol";
import "../src/AaveHelper.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";

contract Oracle_Test is TestUtils {
    function setUp() public {
        setChain();
    }

    function test_etch() public {
        int256 _price = 1800 * 1e8;
        setETHUSDPrice(_price);
        DecimalNumber memory result = getAssetPrice(weth);
        assertEq(result.number / 1e10, uint256(_price));
    }
}
