In progress..

Vault that will deposit WETH into aave v3, and borrow against it to give depositors back their money as USDC. If the health of the vault goes below a threhold, the debt in the vault is converted to WETH. When health is back above threshold, debt is coverted back to USDC.

Vault tracks deposits in USDC value. Depositors are paid their deposits back immediately, or as soon as the vault is able to do so.

Conforms to the ERC4626 standard, using solmate implementation.

Intended to be deployed on Arbitrum.

TODO:
- [] Withdraw function

ROADMAP:
- [] Hedge using TracerDAO
- [] Farm stables using excess collateral in vault