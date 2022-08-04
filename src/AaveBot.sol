//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "./AaveVault.sol";
import "./Interfaces/IPool.sol";
import "./Interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "./Interfaces/IPoolAddressesProvider.sol";
import "openzeppelin/contracts/token/ERC20/ERC20.sol";
import "openzeppelin/contracts/token/ERC20/IERC20.sol";
import "openzeppelin/contracts/interfaces/IERC4626.sol";
import "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "openzeppelin/contracts/utils/math/Math.sol";

error Strategy__DepositIsZero();
error Strategy__WethTransferFailed();

contract AaveBot is AaveVault {
    uint256 public constant MAX_BORROW = 7500;
    uint256 public constant LTV_BIT_MASK = 65535;

    address[] public depositors;
    mapping(address => uint256) public usdcAmountOwed;

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IPool public immutable pool;
    IPriceOracle public immutable oracle;

    constructor(
        address _papAddr,
        address _wethAddr,
        address _usdcAddr,
        string memory _name,
        string memory _symbol
    ) AaveVault(IERC20Metadata(_wethAddr)) ERC20(_name, _symbol) {
        IPoolAddressesProvider _pap = IPoolAddressesProvider(_papAddr);
        pool = IPool(_pap.getPool());
        oracle = IPriceOracle(_pap.getPriceOracle());
        weth = IERC20(_wethAddr);
        usdc = IERC20(_usdcAddr);
    }

    function deposit(uint256 _wethAmount) external {
        console.log("Depositor %s", msg.sender);

        if (_wethAmount == 0) {
            revert Strategy__DepositIsZero();
        }

        uint256 _preTransferAmount = weth.balanceOf(address(this));
        deposit(_wethAmount, msg.sender);
        // weth.transferFrom(msg.sender, address(this), _wethAmount);
        if (weth.balanceOf(address(this)) != _preTransferAmount + _wethAmount) {
            revert Strategy__WethTransferFailed();
        }

        uint256 _amountAsUsdc = PRBMathUD60x18.mul(
            _wethAmount,
            oracle.getAssetPrice(address(weth))
        );

        depositors.push(msg.sender);
        usdcAmountOwed[msg.sender] += _amountAsUsdc;
        console.log("USDC amount owed: %s", _amountAsUsdc);

        main();
    }

    function main() public {
        /*
            TODOS
            -----
            [x] Deposit any available WETH to aave
                [] Check if debt is in weth and can be converted back to stables
                [x] Take out a loan to available limit
            [] Get contract health
            [] Convert debt to WETH if health is low
                [] need to flashloan to pay debt, eth loan to repay flashloan
        */
        (
            uint256 _totalCollateral,
            uint256 _totalDebt,
            uint256 _availableBorrows,
            ,
            ,
            uint256 _health
        ) = pool.getUserAccountData(address(this));

        uint256 _wethBalance = weth.balanceOf(address(this));

        console.log("Contract eth bal %s", _wethBalance);

        if (_wethBalance >= 0.00001 ether) {
            weth.approve(address(pool), _wethBalance);
            pool.deposit(address(weth), _wethBalance, address(this), 0);

            (
                _totalCollateral,
                _totalDebt,
                _availableBorrows,
                ,
                ,
                _health
            ) = pool.getUserAccountData(address(this));

            if (_health >= 1.05 ether) {
                // TODO: Check if debt is in WETH and covert back to usdc
                /*
                 * new loan amount = (totalDeposit * maxBorrowPercent) - existingLoans
                 *
                 * Borrows must be requested in the borrowed asset's decimals.
                 * MAX_BORROW * 10e11 gives correct precision for USDC.
                 */
                uint256 _newLoan = calcNewLoan(
                    _totalCollateral,
                    MAX_BORROW * 10e11
                );

                console.log(
                    "Total depoists USD %s, Available Borrows USD %s, New Loan USD: %s",
                    _totalCollateral,
                    _availableBorrows,
                    _newLoan
                );

                pool.borrow(address(usdc), _newLoan, 1, 0, address(this));
                uint256 _payoutPool = usdc.balanceOf(address(this));

                for (uint256 i = 0; i < depositors.length; i++) {
                    uint256 _sharePercentage = PRBMathUD60x18.div(
                        this.balanceOf(depositors[i]),
                        this.totalSupply()
                    );

                    uint256 _depositorPayout = Math.min(
                        usdcAmountOwed[depositors[i]],
                        PRBMathUD60x18.mul(_payoutPool, _sharePercentage)
                    );

                    usdcAmountOwed[depositors[i]] -= _depositorPayout;
                    usdc.transfer(depositors[i], _depositorPayout);
                }
                console.log("================GOT HERE=================");
            }
        }

        if (_health <= 1.01 ether) {
            // TODO: Covert borrows to weth
            console.log("Start of low health block");
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

    function _priceToEth(uint256 _priceInUsd) public view returns (uint256) {
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
