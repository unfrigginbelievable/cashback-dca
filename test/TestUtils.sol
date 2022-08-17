pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/mocks/MockAggregator.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "../src/AaveHelper.sol";

contract TestUtils is Test, AaveHelper {
    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");
    MockAggregator public newOracle;
    IERC20Metadata public weth;
    address public ethusdOracleAddress;

    constructor() {
        weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        oracle = IPriceOracle(0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7);
        ethusdOracleAddress = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    }

    function setChain() internal {
        vm.chainId(31337);
        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        newOracle = new MockAggregator();
    }

    function setETHUSDPrice(int256 _price) internal {
        bytes memory code = address(newOracle).code;
        vm.etch(ethusdOracleAddress, code);

        MockAggregator existingOracle = MockAggregator(ethusdOracleAddress);
        existingOracle.setLatestAnswer(_price);
    }
}
