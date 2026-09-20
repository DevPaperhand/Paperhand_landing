// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PaperhandVault} from "../src/PaperhandVault.sol";

/// @notice Deploys the vault and wires it in one broadcast.
///
///   forge script script/Deploy.s.sol --rpc-url $RPC --account paperhand --broadcast
///
/// Needs TREASURY in the environment. Everything else is below, in the open, so
/// the diff of this file is the diff of the deployment.
contract Deploy is Script {
    // Robinhood stock tokens, chain 4663
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;

    // Chainlink proxies from the official robinhood-mainnet directory
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant MSFT_FEED = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E;
    address constant SPY_FEED  = 0x319724394D3A0e3669269846abE664Cd621f9f6A;

    /// @dev Stock feeds stop publishing when the market is shut. A Friday close to
    ///      a Monday open is already past two days, and a long weekend more. Four
    ///      days is the smallest window that never blocks a ratchet on a holiday.
    uint32 constant STOCK_STALENESS = 4 days;

    /// @notice Receives the 30% early exit cut and the resale royalties. Set once
    ///         on the vault, permanent afterwards. Override with TREASURY in the
    ///         environment if you ever redeploy against a different one.
    address constant TREASURY = 0x0DA0e3eEfD8B5A6C3D4155888bCb3308281aeA2F;

    function run() external {
        address treasury = vm.envOr("TREASURY", TREASURY);
        require(treasury != address(0), "TREASURY not set");

        vm.startBroadcast();

        PaperhandVault vault = new PaperhandVault(msg.sender);
        vault.setPenaltyRecipient(treasury);

        vault.setFeed(NVDA, NVDA_FEED, STOCK_STALENESS, true);
        vault.setFeed(AAPL, AAPL_FEED, STOCK_STALENESS, true);
        vault.setFeed(TSLA, TSLA_FEED, STOCK_STALENESS, true);
        vault.setFeed(MSFT, MSFT_FEED, STOCK_STALENESS, true);
        vault.setFeed(SPY,  SPY_FEED,  STOCK_STALENESS, true);

        vm.stopBroadcast();

        console.log("PaperhandVault", address(vault));
        console.log("owner         ", vault.owner());
        console.log("treasury      ", vault.penaltyRecipient());
        console.log("creation fee  ", vault.creationFee(), "(free until setPaperhand)");

        // read one price back, so a wrong feed shows up here and not in production
        (bool ok, uint256 p) = vault.priceOrZero(NVDA);
        console.log("NVDA feed live", ok);
        console.log("NVDA price wad", p);
    }
}
