# PaperhandVault

Price range vaults on Robinhood Chain, held as ERC-721 positions.

## Run the tests

    forge test

38 tests, including a fuzzed conservation check: whatever path a vault takes,
every token that went in comes back out exactly once, split between the holder
and the treasury, and the vault is left empty.

## Deploy order

1. `new PaperhandVault(owner)`.
2. `setPenaltyRecipient(treasury)`. One way, and no vault can be opened before it,
   so a penalty can never be stranded. A plain address is fine.
3. `setFeed(token, chainlinkProxy, maxStaleness, true)` for each asset.
   Stock feeds stop updating when the market is shut: give them at least
   four days of staleness, or claims break every weekend.
4. `setSequencerUptimeFeed(feed)` if Chainlink publishes one for the chain.
5. Launch PAPERHAND, then `setPaperhand(token)`. One way.
5b. `setRoyalty(bps)` if 3% is not the number you want. Claim the collection on
   any marketplace that indexes the chain BEFORE renouncing ownership: they read
   `owner()` to prove who you are, and after renouncing it answers zero.
6. Optional: `setRenderer(art)` once the on-chain art contract is deployed, then
   `freezeArt()` when the cards are final.
7. When the whitelist is settled, `renounceOwnership()`. The contract is then
   frozen forever and nobody, including you, can change anything.

## The knobs

| Setting        | Bounds                              | Changeable later |
|----------------|-------------------------------------|------------------|
| Creation fee   | 0, or 1 to 10,000 PAPERHAND         | yes, within the band |
| Penalty        | 30%, hardcoded                      | no |
| Maturity       | 700 days, hardcoded                 | no |
| Dead oracle    | 30 days of silence, hardcoded       | no |
| Treasury       | any address                         | once, then never |
| PAPERHAND      | any ERC-20                          | once, then never |
| Feeds          | per token, with a staleness window  | yes |
| Art            | any renderer                        | until `freezeArt()` |
| Resale royalty | 0 to 5%, paid to the treasury       | yes |

## Feed addresses, Robinhood Chain

From the official Chainlink directory for robinhood-mainnet. All 8 decimals,
24h heartbeat, 0.5% deviation.

| Asset | Token                                      | Feed proxy                                 |
|-------|--------------------------------------------|--------------------------------------------|
| NVDA  | 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC | 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 |
| AAPL  | 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 | 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0 |
| TSLA  | 0x322F0929c4625eD5bAd873c95208D54E1c003b2d | 0x4A1166a659A55625345e9515b32adECea5547C38 |
| MSFT  | 0xe93237C50D904957Cf27E7B1133b510C669c2e74 | 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E |
| SPY   | 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C | 0x319724394D3A0e3669269846abE664Cd621f9f6A |

## When the oracle stops

Nothing the holder does depends on a live price. Claiming and closing both run
off the stored high water mark, so a stale, paused, delisted or permanently dead
feed can never trap a deposit or revert a withdrawal.

On top of that, a feed silent for thirty days makes closing free for that token.
The 30% exists to price impatience, not to tax someone whose oracle stopped
answering. A feed is only counted dead if nobody has read a usable price out of
it for thirty days AND it still refuses to answer at the moment of closing, so a
quiet market is never mistaken for a broken one.

A feed prices one token, which is the share price times the token multiplier,
so it sits above the Nasdaq print and drifts further as dividends reinvest.
That is the number the vault settles on, and the only one that matters here.
