//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "./Interfaces/IPool.sol";
import "./Interfaces/IPriceOracle.sol";
import "./Interfaces/IPoolAddressesProvider.sol";
import "openzeppelin/contracts/token/ERC20/IERC20.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

contract AaveBot {
    uint256 public constant LTV_BIT_MASK = 65535;
    uint256 public constant MAX_BORROW = 7500;

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IPool public immutable pool;
    IPriceOracle public immutable oracle;

    constructor(
        address _pap_addr,
        address _weth_addr,
        address _usdc_addr
    ) {
        IPoolAddressesProvider _pap = IPoolAddressesProvider(_pap_addr);
        pool = IPool(_pap.getPool());
        oracle = IPriceOracle(_pap.getPriceOracle());
        weth = IERC20(_weth_addr);
        usdc = IERC20(_usdc_addr);
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

            (
                uint256 _totalCollateral,
                uint256 _totalDebt,
                uint256 _availableBorrows,
                ,
                ,
                uint256 _health
            ) = pool.getUserAccountData(address(this));

            if (_health >= 1.05 ether) {
                /* 
                    new loan amount in eth = (totalDeposit * maxBorrowPercent) - existing_loans
                */
                (
                    uint256 _loanMaxPercent,
                    uint256 _liqThreshold
                ) = getLoanThresholds(address(weth));

                uint256 _newLoan = calcNewLoan(
                    _totalCollateral,
                    MAX_BORROW * 10e11
                );

                console.log(
                    "Available Borrows USD %s, Available Borrows ETH %s, New Loans: %s",
                    _availableBorrows,
                    _priceToEth(_availableBorrows),
                    _newLoan
                );

                pool.borrow(address(usdc), _newLoan, 1, 0, address(this));

                console.log("================GOT HERE=================");
            }
        }
    }

    function loansInEth() public view returns (uint256) {
        (, uint256 _totalDebt, , , , ) = pool.getUserAccountData(address(this));
        return _priceToEth(_totalDebt);
    }

    function depositsInEth() public view returns (uint256) {
        (uint256 _totalCollateral, , , , , ) = pool.getUserAccountData(
            address(this)
        );
        return _priceToEth(_totalCollateral);
    }

    function _priceToEth(uint256 _priceInUsd) internal view returns (uint256) {
        return
            PRBMathUD60x18.div(
                _priceInUsd,
                oracle.getAssetPrice(address(weth))
            );
    }

    function getLoanThresholds(address _asset)
        public
        view
        returns (uint256, uint256)
    {
        uint256 bits = pool.getReserveData(_asset).configuration.data;
        uint256 ltv = bits & LTV_BIT_MASK;
        uint256 liqThresh = (bits >> 16) & LTV_BIT_MASK;

        return (ltv, liqThresh);
    }

    function calcNewLoan(uint256 _deposits, uint256 _loanPercentage)
        public
        pure
        returns (uint256)
    {
        return PRBMathUD60x18.mul(_deposits, _loanPercentage);
    }
}
