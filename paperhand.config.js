/* =============================================================================
   PAPERHAND ON ELYSIUM: the one file you edit.

   The same file sits in both repos (the landing and the app). Change it, commit,
   done: no build step. Anything left empty shows as "soon" instead of breaking.
   ============================================================================= */
(function () {

  /* ------------------------------------------------------------------ chain
     Elysium is Kinetiq's L2 on Hyperliquid. Gas is HYPE.
     Mainnet details are not public yet: when they are, fill "mainnet" and flip
     NETWORK to "mainnet". Nothing else changes.                               */
  const NETWORKS = {
    testnet: {
      chainId: 99801,
      name: "Elysium Testnet",
      rpc: "https://testnet-rpc.elysium.kinetiq.xyz",
      explorer: "https://explorer-elysium-testnet.t.conduit.xyz",
      native: { name: "HYPE", symbol: "HYPE", decimals: 18 }
    },
    mainnet: {
      chainId: 0,            // TODO: published at mainnet launch
      name: "Elysium",
      rpc: "",               // TODO
      explorer: "",          // TODO
      native: { name: "HYPE", symbol: "HYPE", decimals: 18 }
    }
  };
  const NETWORK = "testnet";

  /* ----------------------------------------------------------------- tokens
     ADD A TOKEN = ADD ONE LINE.

       symbol   ticker shown everywhere
       name     full name
       address  the ERC-20 on Elysium
       feed     its USD price feed (AggregatorV3 interface: Chainlink, or a
                Pyth / RedStone adapter that exposes latestRoundData)
       tint     brand colour, used for the drawn logo and accents
       logo     optional image path or URL, e.g. "logos/kntq.png"
       wraps    true if `address` is the wrapped native coin (WHYPE): the app
                wraps HYPE for you before locking
       swap     optional link to buy it; defaults to SWAP_URL below

     A token with no address or no feed is listed as "soon", visible but not
     lockable. The vault owner still has to call setFeed(token, feed,
     maxStaleness, true) on chain: the app's add-token page prints that call. */
  const TOKENS = [
    { symbol: "HYPE", name: "Hyperliquid", address: "", feed: "", tint: "#97FCE4", logo: "logos/hype.png", wraps: true },
    { symbol: "KNTQ", name: "Kinetiq",     address: "", feed: "", tint: "#5FC4D0", logo: "logos/kntq.png" },
    // { symbol: "kHYPE", name: "Kinetiq Staked HYPE", address: "0x...", feed: "0x...", tint: "#5FD3F3" },
  ];

  /* -------------------------------------------------------------- protocol */
  window.PAPERHAND = {
    NETWORK,
    NET: NETWORKS[NETWORK],
    VAULT: "",          // PaperhandVault on Elysium, once deployed
    TREASURY: "",       // receives penalties, fees and royalties
    PAPERHAND: "",      // the token; empty means vaults are free
    MAX_FEED_AGE: 90000, // seconds; crypto feeds beat at least daily
    FEES: { buy: 2, sell: 2 },
    SWAP_URL: "",       // e.g. "https://<dex>/swap?output={address}"; {address} is replaced
    MARKET_URL: "",     // where vault NFTs trade on Elysium, once there is one
    MARKET_NAME: "",    // e.g. "OpenSea"
    TOKENS,
    LINKS: {
      site: "https://paperhand.trade",
      app: "https://lock.paperhand.trade",
      github: "https://github.com/DevPaperhand",
      x: "https://x.com/tradepaperhand",
      telegram: "",
      docs: "",
      paperhand: ""
    }
  };
})();
