# Yield Fields Deed (YFD)

A fixed-supply ERC-20 for a custom-token launch on Robinhood Chain (chain id 4663).

| | |
|---|---|
| Solidity contract | `YFDToken` (`src/YFDToken.sol`) |
| `name()` | Yield Fields Deed |
| `symbol()` | YFD |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 YFD = `1000000000000000000000000000` minor units |
| Constructor arguments | none |

## Behaviour

- The constructor mints the whole supply once to `msg.sender` (the launch factory). No other
  code path mints, so the supply can never grow.
- Standard OpenZeppelin v5.1.0 ERC-20 (vendored under `lib/openzeppelin-contracts`): transfers,
  approvals and `transferFrom` behave exactly as ERC-20 specifies. No fee, tax, burn or rebasing,
  so the factory's distributor transfer, the pool seed and swaps through the Uniswap v4
  PoolManager move exactly the amounts they state.
- No owner and no administrative functions: nothing can pause, freeze, blacklist, seize or
  burn a holder's balance. No DELEGATECALL, CALLCODE or SELFDESTRUCT; no libraries to link.

## Deployment parameters

The token is deployed by the IMD launch through `ProjectFactory.launchCustom`; this repository
contains no deploy script and performs no transactions.

- `token.contract`: `YFDToken`, constructor args: none, `totalSupply`: `1000000000000000000000000000`, decimals 18.
- No application contracts.
- Pool, fee and economics are the launch's (IMD pair, fee 12500, tick spacing 60, economics as
  given by the requester) and are written into `launch.json` by the manifest step, not here.

## Assumptions

- The brief asks only for a plain token with a fixed supply; no transfer rules were requested,
  so none were added.
- Compiler pinned to solc 0.8.26 with the optimizer (200 runs) and `bytecode_hash = "none"`.

## After launch

Nothing to configure: the token has no owner and no settings.

## Operational responsibilities

- The factory distributes the supply (swarm share, pool seed, remainder to the requester) at
  launch; after that the token needs no operator.
- Holders are responsible for their own keys and approvals. Lost tokens (e.g. sent to a wrong
  address) cannot be recovered by anyone.

## Development

```
forge build
forge test
forge fmt --check
```

Tests are in `test/YFDToken.t.sol`. Passing tests are not a security audit.
