# Primitive Hyper RMM

Full vision of Primitive Replicating Market Maker.

## Notes

- [ ] Investigate use of msg.value! (used in fund).
- [x] Improve/fix swap. Assigned to Clement.
- [ ] Investigate gas costs of swaps.
- [x] Investigate curve/pair nonces. Assigned to Alex.
- [ ] Add utility functions to fetch all data. Assigned to Alex.
- [ ] Add random swaps to invariant testing.
- [ ] Investigate typecasting.
- [ ] Investiate assembly usage.
- [ ] Explore refactor of free functions. I like free functions but they are so new that not many testing frameworks have good support yet.
- [ ] Explore implications of time movement creating price changes. Cannot change price and liquidity at the same time, thats an invariant!

#### Allocate

Adding liquidity increases pool and position liquidity balances, and charges the caller the virtual balances of tokens required to back that liquidity.

Virtual balances depend on price.

Price should not change when adding liquidity.

If liquidity changes, virtual balances need to be updated, which would require tokens to be paid to the contract.

Changing a position:

- Timestamp synced
- Fees are synced
- Position Liquidity is touched
  - Pool is touched
    - Reserves are touched

#### Notes

- Increasing reserves but paying entirely with internal balance leads to a deficit and therefore invariant failure.
