# Uniswap V3 Liquidity DAO

For more details, see https://hackmd.io/@dmihal/uniswap-liquidity-dao

This protocol aims to provide a Uniswap V2 user experience for Uniswap V3.

Anyone can create a "MetaPool" of two tokens, which will be automatically allocated to the
Uniswap pool & curve allocation determined by the DAO. Accrued fees are automatically compounded,
and liquidity is represented as a fungible ERC20 token.

## Status

The MetaPool & MetaPool Factory are functional and integrated with the Uniswap V3 codebase. Users can deposit and withdraw funds from the pool. The protocol owner (currently a single address) can adjust pool paramaters, and any account may call `rebalance()` to claim fees and re-allocate funds.

The primary issue the project is facing is front-running: currently a miner can run a "sandwich attack" to skew the pool price before a rebalancing call.

## Want to contribute? Want to use this code in your project?

DM me :)

@dmihal
