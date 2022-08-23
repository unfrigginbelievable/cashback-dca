pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/mocks/MockAggregator.sol";
import "src/mocks/MockSwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "../src/AaveHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "src/BridgedERC20.sol";

contract TestUtils is Test, AaveHelper {
    string public ARBITRUM_RPC_URL = vm.envString("ALCHEMY_WEB_URL");
    MockAggregator public newOracle;
    MockSwapRouter public newRouter;
    IERC20Metadata public weth;
    IERC20Metadata public usdc;
    address public ethusdOracleAddress;

    constructor() {
        weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        usdc = IERC20Metadata(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
        oracle = IPriceOracle(0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7);
        ethusdOracleAddress = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    }

    function setChain() internal {
        vm.chainId(31337);
        uint256 forkId = vm.createFork(ARBITRUM_RPC_URL, 19227458);
        vm.selectFork(forkId);

        newOracle = new MockAggregator();
        newRouter = new MockSwapRouter();
    }

    function setETHUSDPrice(int256 _price) internal {
        bytes memory code = address(newOracle).code;
        vm.etch(ethusdOracleAddress, code);

        MockAggregator existingOracle = MockAggregator(ethusdOracleAddress);
        existingOracle.setLatestAnswer(_price);
    }

    function spoofUniswapRouter(uint256 _price, uint256 _decimals)
        internal
        returns (MockSwapRouter)
    {
        console.log("Spoof %s", address(weth));
        bytes memory code = address(newRouter).code;
        vm.etch(address(router), code);

        // overwrite the old state vars of the router with the new vars
        for (uint256 i = 0; i < 20; i++) {
            vm.store(
                address(router),
                bytes32(uint256(i)),
                vm.load(address(newRouter), bytes32(uint256(i)))
            );
        }

        MockSwapRouter existingRouter = MockSwapRouter(address(router));
        existingRouter.setSwapRate(_price, _decimals);
        return existingRouter;
    }

    function mintWETH(uint256 _amount) internal {
        address(weth).call{value: _amount}("");
    }

    function mintUSDC(address _to, uint256 _amount) internal {
        BridgedERC20 _usdc = BridgedERC20(address(usdc));
        vm.prank(_usdc.gatewayAddress());
        _usdc.bridgeMint(_to, _amount);
    }

    /*
    function findMint(
        BridgedERC20 _asset,
        address _account,
        uint256 _amount
    ) public {
        MintType _mintType = mintType[address(_asset)];
        if (_mintType == MintType.Native) {
            _asset.mint(_account, _amount);
        } else {
            _asset.bridgeMint(_account, _amount);
        }
    }*/
}
