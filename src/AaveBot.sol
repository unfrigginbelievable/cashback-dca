//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./AaveHelper.sol";
import "./ERC4626.sol";
import "forge-std/console.sol";
import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "aave/contracts/interfaces/IPoolAddressesProvider.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "aave/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

error Strategy__DepositIsZero();
error Strategy__WethTransferFailed();
error Strategy__InitiatorNotContract();

contract AaveBot is AaveHelper, ERC4626, IFlashLoanSimpleReceiver {
    enum DebtStatus {
        Stables,
        weth
    }

    DecimalNumber public MAX_BORROW = DecimalNumber({number: 7500 * 1e14, decimals: 18});
    uint256 public constant LOW_HEALTH_THRESHOLD = 1.05 ether;
    uint256 public constant MIN_BORROW_AMOUNT = 1 ether;

    address[] public depositors;
    mapping(address => uint256) public usdcAmountOwed;
    mapping(address => uint256) public usdcAmountPaid;

    DebtStatus public debtStatus;
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
    ) ERC4626(ERC20(_usdcAddr), _name, _symbol) {
        pap = IPoolAddressesProvider(_papAddr);
        pool = IPool(pap.getPool());
        oracle = IPriceOracle(pap.getPriceOracle());
        weth = IERC20Metadata(_wethAddr);
        usdc = IERC20Metadata(_usdcAddr);
        router = ISwapRouter(_uniswapRouterAddr);
        debtStatus = DebtStatus.Stables;
    }

    function addToDepositors(address _user) internal {
        bool _inDepositors = false;
        for (uint256 i = 0; i < depositors.length; i++) {
            if (depositors[i] == _user) {
                _inDepositors = true;
                break;
            }
        }

        if (!_inDepositors) {
            depositors.push(_user);
        }
    }

    function main() public {
        (
            DecimalNumber memory _totalCollateralUSD,
            DecimalNumber memory _totalDebtUSD,
            DecimalNumber memory _availableBorrowsUSD,
            ,
            ,
            DecimalNumber memory _health
        ) = getUserDetails(address(this));

        DecimalNumber memory _wethBalance = getBalanceOf(weth, address(this));

        // Deposit weth to AAVE
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
        }

        // Payout depositors if new borrow can be made
        if (_health.number > LOW_HEALTH_THRESHOLD) {
            /*
             * new loan amount = (totalDeposit * maxBorrowPercent) - existingLoans
             */
            if (debtStatus == DebtStatus.weth) {
                /*
                 * Converts weth debt into usdc debt.
                 * See executeOperation() below.
                 */
                DecimalNumber memory _totalDebtWETH = fixedDiv(_totalDebtUSD, getAssetPrice(weth));
                pool.flashLoanSimple(address(this), address(weth), _totalDebtWETH.number, "", 0);
                debtStatus = DebtStatus.Stables;
                (
                    _totalCollateralUSD,
                    _totalDebtUSD,
                    _availableBorrowsUSD,
                    ,
                    ,
                    _health
                ) = getUserDetails(address(this));
            }

            DecimalNumber memory _newLoanUSD = calcNewLoan(
                _totalCollateralUSD,
                _totalDebtUSD,
                MAX_BORROW
            );

            // AKA only run if 1 USDC or more can be borrowed
            if (_newLoanUSD.number >= MIN_BORROW_AMOUNT) {
                DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);
                DecimalNumber memory _borrowAmountUSDC = truncate(
                    fixedDiv(_newLoanUSD, _usdcPriceUSD),
                    6
                );

                pool.borrow(address(usdc), _borrowAmountUSDC.number, 1, 0, address(this));
                executePayouts();
            }
        } else if (_health.number <= LOW_HEALTH_THRESHOLD) {
            /*
             * Converts usdc debt into weth debt.
             * See executeOperation() below.
             */
            if (debtStatus == DebtStatus.Stables) {
                DecimalNumber memory _totalDebtUSDC = truncate(
                    fixedDiv(_totalDebtUSD, getAssetPrice(usdc)),
                    6
                );
                pool.flashLoanSimple(address(this), address(usdc), _totalDebtUSDC.number, "", 0);
                debtStatus = DebtStatus.weth;
            }
        }
    }

    function executePayouts() internal {
        uint256 _payoutPool = usdc.balanceOf(address(this));
        for (uint256 i = 0; i < depositors.length; i++) {
            DecimalNumber memory _userShares = getBalanceOf(
                IERC20Metadata(address(this)),
                depositors[i]
            );
            uint256 _usdcOwed = usdcAmountOwed[depositors[i]];

            // Remove the depositor if they no longer are owed any money and have no stake in vault
            if (_userShares.number == 0 && _usdcOwed == 0) {
                removeDepositor(depositors[i]);
                continue;
            }

            DecimalNumber memory _sharePercentage = fixedDiv(
                _userShares,
                DecimalNumber({number: this.totalSupply(), decimals: asset.decimals()})
            );

            uint256 _depositorPayout = Math.min(
                _usdcOwed,
                fixedMul(DecimalNumber(_payoutPool, asset.decimals()), _sharePercentage).number
            );

            usdcAmountOwed[depositors[i]] -= _depositorPayout;
            usdcAmountPaid[depositors[i]] += _depositorPayout;
            usdc.transfer(depositors[i], _depositorPayout);
        }
    }

    /* ================================================================
                            ERC4626 METHODS
       ================================================================ */
    /**
     * @dev Cannot return 0. Breaks deposits
     */
    function totalAssets() public view override returns (uint256) {
        /*
         * (availableBorrows * 0.75) / usdcPriceUSD
         */
        (DecimalNumber memory _depositsUSD, , , , , ) = getUserDetails(address(this));
        DecimalNumber memory _usdcPriceUSD = getAssetPrice(usdc);
        return
            truncate(fixedDiv(fixedMul(_depositsUSD, MAX_BORROW), _usdcPriceUSD), asset.decimals())
                .number;
    }

    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        usdcAmountOwed[msg.sender] += (assets - usdcAmountPaid[msg.sender]);
        main();
    }

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        addToDepositors(msg.sender);
        usdcAmountOwed[msg.sender] += assets;

        DecimalNumber memory _decAssets = addPrecision(
            DecimalNumber({number: assets / 1e12, decimals: asset.decimals()}),
            18
        );

        DecimalNumber memory _wethOut = calculateSwapOutAmount(
            usdc,
            weth,
            _decAssets,
            UNI_POOL_FEE,
            MAX_SLIPPAGE
        );

        swapAssetsExactInput(usdc, weth, _wethOut);
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

        if (initiator != address(this)) {
            revert Strategy__InitiatorNotContract();
        }

        if (debtStatus == DebtStatus.Stables) {
            DecimalNumber memory _paybackAmountInWei = addPrecision(
                DecimalNumber({
                    number: amount + premium,
                    decimals: IERC20Metadata(asset).decimals()
                }),
                18
            );

            // swap borrowed eth to usdc
            // swapDebt does all the calculations for me lol
            uint256 _wethUsed = swapDebt(usdc, weth, _paybackAmountInWei, 1, 2);

            DecimalNumber memory _leftOverWeth = getBalanceOf(weth, address(this));
            // TODO: Pay back unused weth
            // if (_leftOverWeth.number > 0) {
            //     weth.approve(address(pool), _leftOverWeth.number);
            //     pool.repay(address(weth), _leftOverWeth.number, 2, address(this));
            // }

            // Ensure pool can transfer back borrowed asset
            usdc.approve(address(pool), truncate(getBalanceOf(usdc, address(this)), 6).number);
        } else if (debtStatus == DebtStatus.weth) {
            // TODO: Swap from weth debt to usdc debt
            DecimalNumber memory _paybackAmountInWei = addPrecision(
                DecimalNumber({
                    number: amount + premium,
                    decimals: IERC20Metadata(asset).decimals()
                }),
                18
            );

            uint256 _wethUsed = swapDebt(weth, usdc, _paybackAmountInWei, 2, 1);

            DecimalNumber memory _leftOverUSDC = getBalanceOf(usdc, address(this));
            // TODO: Pay back unused usdc
            // if (_leftOverWeth.number > 0) {
            //     weth.approve(address(pool), _leftOverWeth.number);
            //     pool.repay(address(weth), _leftOverWeth.number, 2, address(this));
            // }

            // Ensure pool can transfer back borrowed asset
            weth.approve(address(pool), getBalanceOf(weth, address(this)).number);
        }

        return true;
    }

    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return pap;
    }

    function POOL() external view returns (IPool) {
        return pool;
    }

    /* ================================================================
                                    MISC
       ================================================================ */
    // Shamelessly stolen from: https://solidity-by-example.org/array/
    // Last element copied over the element we want to delete, then we pop the last element
    function removeDepositor(address _depositor) internal {
        uint256 removeIndex = findIndexOfDepositor(_depositor);
        depositors[removeIndex] = depositors[depositors.length - 1];
        depositors.pop();
    }

    function findIndexOfDepositor(address _depositor) internal returns (uint256 index) {
        for (uint256 i = 0; i < depositors.length; i++) {
            if (depositors[i] == _depositor) {
                index = i;
                break;
            }
        }
    }
}
