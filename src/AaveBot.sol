//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "./Interfaces/IPool.sol";
import "./Interfaces/IPriceOracle.sol";
import "./Interfaces/IPoolAddressesProvider.sol";
import "openzeppelin/contracts/token/ERC20/IERC20.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

contract AaveBot {
    IERC20 public immutable weth;
    IPool public immutable pool;
    IPriceOracle public immutable oracle;

    constructor(address _pap_addr, address _weth_addr) {
        IPoolAddressesProvider _pap = IPoolAddressesProvider(_pap_addr);
        pool = IPool(_pap.getPool());
        oracle = IPriceOracle(_pap.getPriceOracle());
        weth = IERC20(_weth_addr);
        // TODO: Set emode for this contract
    }

    function deposit() external {}

    function main() external {
        /*
            TODOS
            -----
            [] Deposit any available WETH to aave
            [] Check if debt is in weth and can be converted back to stables
            [] Take out a loan to available limit
            [] Get contract health
            [] Convert debt to WETH if health is low
                [] need to flashloan to pay debt, turn off emode, eth loan to repay flashloan
        */
        uint256 _wethBalance = weth.balanceOf(address(this));

        console.log("Contract bal %s", _wethBalance);

        if (_wethBalance >= 0.00001 ether) {
            weth.approve(address(pool), _wethBalance);
            pool.deposit(address(weth), _wethBalance, address(this), 0);
            (, , , , , uint256 _health) = pool.getUserAccountData(
                address(this)
            );

            if (_health >= 1.05 ether) {}
        }
    }

    function reservesInEth() public view returns (uint256) {
        (uint256 _totalCollateral, , , , , ) = pool.getUserAccountData(
            address(this)
        );
        return
            PRBMathUD60x18.div(
                _totalCollateral,
                oracle.getAssetPrice(address(weth))
            );
    }
}
