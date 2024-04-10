# Trend Strategy for Haiko AMM

The Trend Strategy operates on a trend classification (`Up`, `Down` or `Ranging`) to place self-rebalancing liquidity positions in Haiko AMM.

Positions automatically follow the price of a token pair on either single or double-sided price action, similar to Left and Right modes in [Maverick Protocol](https://www.mav.xyz/).

Unlike the first [Replicating Strategy](https://haiko-docs.gitbook.io/docs/protocol/strategy-vaults/live-vaults/replicating-strategy) for Haiko:

1. It does not rely on an external oracle price, allowing for use with a much wider range of pairs.
2. Vault positions are now tracked with a corresponding ERC20 token, allowing for greater composability with other DeFi protocols.

Trend classification is currently computed off-chain and brought on-chain via a state update. This can be done trustlessly with a verifiable ML model e.g. with [Giza](https://www.gizatech.xyz/).

## Getting started

```shell
# Run the tests
snforge test

# Build contracts
scarb build
```

## Version control

- [Scarb](https://github.com/software-mansion/scarb) 2.6.3
- [Cairo](https://github.com/starkware-libs/cairo) 2.6.3
- [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry) 0.21.0
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/cairo-contracts/) 0.11.0
