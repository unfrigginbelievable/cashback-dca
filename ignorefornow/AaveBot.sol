//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "./AaveHelper.sol";
import "aave/contracts/interfaces/IPool.sol";
import "aave/contracts/interfaces/IPriceOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "aave/contracts/interfaces/IPoolAddressesProvider.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "aave/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";

error Strategy__DepositIsZero();
error Strategy__WethTransferFailed();

contract AaveBot is AaveHelper, IERC4626, ERC20, IFlashLoanSimpleReceiver {
    using Math for uint256;

    IERC20Metadata private immutable _asset;

    uint256 public constant MAX_BORROW = 7500;
    uint256 public constant LTV_BIT_MASK = 65535;

    address[] public depositors;
    mapping(address => uint256) public usdcAmountOwed;

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IPoolAddressesProvider public immutable pap;
    IPool public immutable pool;
    IPriceOracle public immutable oracle;
    ISwapRouter public immutable router;

    constructor(
        address _papAddr,
        address _wethAddr,
        address _usdcAddr,
        address _uniswapRouterAddr,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        pap = IPoolAddressesProvider(_papAddr);
        pool = IPool(pap.getPool());
        oracle = IPriceOracle(pap.getPriceOracle());
        weth = IERC20(_wethAddr);
        usdc = IERC20(_usdcAddr);
        router = ISwapRouter(_uniswapRouterAddr);
        _asset = IERC20Metadata(_wethAddr);
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

            (_totalCollateral, _totalDebt, _availableBorrows, , , _health) = pool
                .getUserAccountData(address(this));

            if (_health >= 1.05 ether) {
                // TODO: Check if debt is in WETH and covert back to usdc
                /*
                 * new loan amount = (totalDeposit * maxBorrowPercent) - existingLoans
                 *
                 * Borrows must be requested in the borrowed asset's decimals.
                 * MAX_BORROW * 10e11 gives correct precision for USDC.
                 */
                uint256 _newLoan = calcNewLoan(_totalCollateral, MAX_BORROW * 10e11);

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

            /*
             * Converts usdc debt into weth debt.
             * See executeOperation() below.
             */
            pool.flashLoanSimple(address(this), address(usdc), _totalDebt, "", 0);
        }
    }

    function loansInEth() public view returns (uint256) {
        (, uint256 _totalDebt, , , , ) = pool.getUserAccountData(address(this));
        return _priceToEth(_totalDebt);
    }

    function depositsInEth() public view returns (uint256) {
        (uint256 _totalCollateral, , , , , ) = pool.getUserAccountData(address(this));
        return _priceToEth(_totalCollateral);
    }

    function _priceToEth(uint256 _priceInUsd) public view returns (uint256) {
        uint256 _oraclePrice = oracle.getAssetPrice(address(weth));
        uint256 _result = PRBMathUD60x18.div(_priceInUsd, _oraclePrice);
        return _result;
    }

    function getLoanThresholds(address _asset) public view returns (uint256, uint256) {
        uint256 bits = pool.getReserveData(_asset).configuration.data;
        uint256 ltv = bits & LTV_BIT_MASK;
        uint256 liqThresh = (bits >> 16) & LTV_BIT_MASK;

        return (ltv, liqThresh);
    }

    function calcNewLoan(uint256 _deposits, uint256 _loanPercentage) public pure returns (uint256) {
        return PRBMathUD60x18.mul(_deposits, _loanPercentage);
    }

    /*
     * ================================================================
     * ====================== ERC 4626 METHODS ========================
     * ================================================================
     */

    /** @dev See {IERC4262-asset}. */
    function asset() public view virtual override returns (address) {
        return address(_asset);
    }

    /** @dev See {IERC4262-totalAssets}. */
    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function totalAssets() public view virtual override returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /** @dev See {IERC4262-convertToShares}. */
    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function convertToShares(uint256 assets) public view virtual override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function convertToAssets(uint256 shares) public view virtual override returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /** @dev See {IERC4262-maxDeposit}. */
    function maxDeposit(address) public view virtual override returns (uint256) {
        return _isVaultCollateralized() ? type(uint256).max : 0;
    }

    /** @dev See {IERC4262-maxMint}. */
    function maxMint(address) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /** @dev See {IERC4262-maxWithdraw}. */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Down);
    }

    /** @dev See {IERC4262-maxRedeem}. */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        return balanceOf(owner);
    }

    /** @dev See {IERC4262-previewDeposit}. */
    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    /** @dev See {IERC4262-previewMint}. */
    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    /** @dev See {IERC4262-previewWithdraw}. */
    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Up);
    }

    /** @dev See {IERC4262-previewRedeem}. */
    // TODO: Does this work if assets = totalCollateral - totalDebt?
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /** @dev See {IERC4262-deposit}. */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        require(assets <= maxDeposit(receiver), "ERC4626: deposit more than max");

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /** @dev See {IERC4262-mint}. */
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        require(shares <= maxMint(receiver), "ERC4626: mint more than max");

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /** @dev See {IERC4262-withdraw}. */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /** @dev See {IERC4262-redeem}. */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     *
     * Will revert if assets > 0, totalSupply > 0 and totalAssets = 0. That corresponds to a case where any asset
     * would represent an infinite amout of shares.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256 shares)
    {
        uint256 supply = totalSupply();
        return
            (assets == 0 || supply == 0)
                ? assets.mulDiv(10**decimals(), 10**_asset.decimals(), rounding)
                : assets.mulDiv(supply, totalAssets(), rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256 assets)
    {
        uint256 supply = totalSupply();
        return
            (supply == 0)
                ? shares.mulDiv(10**_asset.decimals(), 10**decimals(), rounding)
                : shares.mulDiv(totalAssets(), supply, rounding);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual {
        // If _asset is ERC777, `transferFrom` can trigger a reenterancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transfered and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        console.log("Depositor %s", msg.sender);

        if (assets == 0) {
            revert Strategy__DepositIsZero();
        }

        uint256 _preTransferAmount = weth.balanceOf(address(this));

        SafeERC20.safeTransferFrom(_asset, caller, address(this), assets);

        // weth.transferFrom(msg.sender, address(this), assets);
        if (weth.balanceOf(address(this)) != _preTransferAmount + assets) {
            revert Strategy__WethTransferFailed();
        }

        _mint(receiver, shares);

        uint256 _amountAsUsdc = PRBMathUD60x18.mul(assets, oracle.getAssetPrice(address(weth)));

        depositors.push(msg.sender);
        usdcAmountOwed[msg.sender] += _amountAsUsdc;
        console.log("USDC amount owed: %s", _amountAsUsdc);

        main();

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transfered, which is a valid state.
        _burn(owner, shares);
        SafeERC20.safeTransfer(_asset, receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _isVaultCollateralized() private view returns (bool) {
        return totalAssets() > 0 || totalSupply() == 0;
    }

    /* ================================================================
     * ========================= FLASHLOAN FUNCTIONS ==================
     * ================================================================
     */

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

        // This is how much usdc aave expects back + uniswap fee
        uint256 _uniswapFee = Math.mulDiv(amount, uniPoolFee, feeDenominator);
        uint256 _paybackAmount = amount + premium + _uniswapFee;

        console.log("Payback amount: %s", _paybackAmount);

        // pay back debt
        pool.repay(asset, amount, 1, initiator);

        // take out new debt in eth
        uint256 _newDebt = _priceToEth(_paybackAmount);
        pool.borrow(address(weth), _newDebt, 1, 0, initiator);

        // swap borrowed eth to usdc
        uint256 _amountIn = swapDebt(weth, usdc, _paybackAmount, router, pool);

        if (_amountIn < _paybackAmount) {
            uint256 _leftOver = _paybackAmount - _amountIn;
            weth.approve(address(pool), _leftOver);
            pool.repay(address(weth), _leftOver, 1, address(this));
        }

        // Ensure pool can transfer back borrowed asset
        usdc.approve(address(pool), _paybackAmount);
    }

    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return pap;
    }

    function POOL() external view returns (IPool) {
        return pool;
    }

    /* ================================================================
     * ========================= UNISWAP FUNCTIONS ==================
     * ================================================================
     */
}
