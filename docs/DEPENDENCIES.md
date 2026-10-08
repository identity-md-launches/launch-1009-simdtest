# Vendored dependencies

Only the transitive Solidity sources needed by this project and tests are retained. These are ordinary files, not git submodules. No network fetch is required to build.

## forge-std

```text
foundry-rs/forge-std
ref: master
commit: 0258fe875e1d8e207c1eb7175e542ea32356773c
```

## openzeppelin-contracts

```text
OpenZeppelin/openzeppelin-contracts
ref: v5.1.0
commit: 69c8def5f222ff96f2b5beff05dfba996368aa79
```

## solmate

```text
transmissions11/solmate
Owned.sol commit: 89365b880c4f3c786bdd453d4b8e8fe410344a69
```

## v4-core

```text
Uniswap/v4-core
ref: main
commit: 46c6834698c48bc4a463a86d8420f4eb1d7f3b75
```

All retained upstream Solidity source files are unmodified. Solmate Owned.sol is the only required Solmate contract. Upstream licenses are retained in each directory (Uniswap provides licenses/BUSL_LICENSE and licenses/MIT_LICENSE). v4-core PoolManager is an integration/test dependency; the launch hook imports its interfaces, types and libraries.
