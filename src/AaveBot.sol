//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";

import "./AaveHelper.sol";

import "@solmate/mixins/ERC4626.sol";
import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "aave/contracts/interfaces/IPoolAddressesProvider.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "aave/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

error Strategy__DepositIsZero();
error Strategy__WethTransferFailed();

contract AaveBot is AaveHelper, ERC4626, IFlashLoanSimpleReceiver {
    using Math for uint256;

    DecimalNumber public MAX_BORROW = DecimalNumber({number: 7500 * 1e14, decimals: 18});
    uint256 public constant LTV_BIT_MASK = 65535;
    uint256 public constant LOW_HEALTH_THRESHOLD = 1.05 ether;

    address[] public depositors;
    mapping(address => uint256) public usdcAmountOwed;

    IERC20Metadata public immutable weth;
    IERC20Metadata public immutable usdc;
    IPoolAddressesProvider public immutable pap;

    constructor(
        address _papAddr,
        address _wethAddr,
        address _usdcAddr,
        address _uniswapRouterAddr,
        string memory _name,
        string memory _symbol
    ) ERC4626(ERC20(_wethAddr), _name, _symbol) {
        pap = IPoolAddressesProvider(_papAddr);
        pool = IPool(pap.getPool());
        oracle = IPriceOracle(pap.getPriceOracle());
        weth = IERC20Metadata(_wethAddr);
        usdc = IERC20Metadata(_usdcAddr);
        router = ISwapRouter(_uniswapRouterAddr);
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
            DecimalNumber memory _totalCollateralUSD,
            DecimalNumber memory _totalDebtUSD,
            DecimalNumber memory _availableBorrowsUSD,
            ,
            ,
            DecimalNumber memory _health
        ) = getUserDetails(address(this));

        DecimalNumber memory _wethBalance = getBalanceOf(weth, address(this));

        console.log("Contract eth bal %s", _wethBalance.number);

        if (_wethBalance.number >= 0.00001 ether) {
            weth.approve(address(pool), _wethBalance.number);
            pool.deposit(address(weth), _wethBalance.number, address(this), 0);

            (
                _totalCollateralUSD,
                _totalDebtUSD,
                _availableBorrowsUSD,
                ,
                ,
                _health
            ) = getUserDetails(address(this));

            if (_health.number >= 1.05 ether) {
                // TODO: Check if debt is in WETH and covert back to usdc
                /*
                 * new loan amount = (totalDeposit * maxBorrowPercent) - existingLoans
                 *
                 * Borrows must be requested in the borrowed asset's decimals.
                 * MAX_BORROW * 10e11 gives correct precision for USDC.
                 */
                DecimalNumber memory _newLoanUSD = calcNewLoan(_totalCollateralUSD, MAX_BORROW);

                console.log(
                    "Total depoists USD %s, Available Borrows USD %s, New Loan USD: %s",
                    _totalCollateralUSD.number,
                    _availableBorrowsUSD.number,
                    _newLoanUSD.number
                );

                DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);
                DecimalNumber memory _borrowAmountUSDC = removePrecision(
                    fixedDiv(_newLoanUSD, _usdcPriceUSD),
                    6
                );

                console.log("Borrowing in USDC %s", _borrowAmountUSDC.number);

                pool.borrow(address(usdc), _borrowAmountUSDC.number, 1, 0, address(this));
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

        if (_health.number <= LOW_HEALTH_THRESHOLD) {
            console.log("Start of low health block");

            /*
             * Converts usdc debt into weth debt.
             * See executeOperation() below.
             * need to borrow (totalDebt * uniswapfee * uniswapslippage)
             */
            DecimalNumber memory _totalDebtUSDC = fixedDiv(_totalDebtUSD, getAssetPrice(usdc));
            console.log("Flashloaning USDC: %s", _totalDebtUSDC.number);
            pool.flashLoanSimple(address(this), address(usdc), _totalDebtUSDC.number, "", 0);
        }
    }

    /* ================================================================
                            ERC4626 METHODS
       ================================================================ */

    function totalAssets() public view override returns (uint256) {}

    function beforeWithdraw(uint256 assets, uint256 shares) internal override {}

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        DecimalNumber memory _wethAmount = DecimalNumber({number: assets, decimals: 18});
        DecimalNumber memory _wethPriceUSD = getAssetPrice(weth);
        DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);

        // (_wethAmount * _wethPriceUSD) / _usdcPriceUSD -> to six decimal places
        DecimalNumber memory _amountAsUsdc = removePrecision(
            fixedDiv(fixedMul(_wethAmount, _wethPriceUSD), _usdcPriceUSD),
            6
        );

        depositors.push(msg.sender);
        usdcAmountOwed[msg.sender] += _amountAsUsdc.number;
        console.log("ETH price %s", _wethPriceUSD.number);
        console.log("USDC amount owed: %s", _amountAsUsdc.number);

        main();
    }

    /* ================================================================
                        FLASHLOAN FUNCTIONS
       ================================================================ */

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        /*
         * Flow:
         * FlashLoan usdc to pay back debt
         * Take out new debt in ETH, ensure eth value = _paybackAmount
         * Swap loaned ETH to usdc via uniswap. Again, ensure usdc = _paybackAmount
         */

        console.log("In flashloan func!");

        // DecimalNumber memory _amountInWei = addPrecision(
        //     DecimalNumber({number: amount, decimals: IERC20Metadata(asset).decimals()}),
        //     18
        // );
        // DecimalNumber memory _premiumInWei = addPrecision(
        //     DecimalNumber({number: premium, decimals: IERC20Metadata(asset).decimals()}),
        //     18
        // );

        // // This is how much usdc to borrow.
        // // Existing debt + aave premium + uniswap fee + slippage
        // DecimalNumber memory _uniswapFee = fixedMul(_amountInWei, UNI_POOL_FEE);
        // DecimalNumber memory _slippage = fixedMul(_amountInWei, MAX_SLIPPAGE);
        // DecimalNumber memory _borrowAmountInUSDC = DecimalNumber({
        //     number: _amountInWei.number +
        //         _premiumInWei.number +
        //         _uniswapFee.number +
        //         _slippage.number,
        //     decimals: 18
        // });

        // console.log("Borrow amount: %s", _borrowAmountInUSDC.number);

        // // pay back debt
        // pool.repay(asset, amount, 1, initiator);

        // // take out new debt in eth
        // DecimalNumber memory _newDebt = convertPriceDenomination(weth, usdc, _borrowAmountInUSDC);
        // console.log("WETH borrow amount %s", _newDebt.number);
        // pool.borrow(address(weth), _newDebt.number, 1, 0, initiator);

        DecimalNumber memory _paybackAmountInWei = addPrecision(
            DecimalNumber({number: amount + premium, decimals: IERC20Metadata(asset).decimals()}),
            18
        );

        // swap borrowed eth to usdc
        // swapDebt does all the calculations for me lol
        swapDebt(usdc, weth, _paybackAmountInWei, 1, 2);

        DecimalNumber memory _leftOverWeth = getBalanceOf(weth, address(this));

        if (_leftOverWeth.number > 0) {
            weth.approve(address(pool), _leftOverWeth.number);
            pool.repay(address(weth), _leftOverWeth.number, 1, address(this));
        }

        // Ensure pool can transfer back borrowed asset
        usdc.approve(address(pool), removePrecision(getBalanceOf(usdc, address(this)), 6).number);

        return true;
    }

    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return pap;
    }

    function POOL() external view returns (IPool) {
        return pool;
    }
}
