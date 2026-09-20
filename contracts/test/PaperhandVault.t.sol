// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaperhandVault} from "../src/PaperhandVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public feeBps; // fee on transfer, to prove the accounting holds
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function setFee(uint256 bps) external { feeBps = bps; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { return _move(msg.sender, to, a); }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        return _move(f, to, a);
    }
    function _move(address f, address to, uint256 a) internal returns (bool) {
        balanceOf[f] -= a;
        uint256 fee = (a * feeBps) / 10_000;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
        return true;
    }
}

contract MockFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    bool public broken;

    constructor(int256 a){ answer = a; updatedAt = block.timestamp; }
    function set(int256 a) external { answer = a; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 u) external { updatedAt = u; }
    function setBroken(bool b) external { broken = b; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract PaperhandVaultTest is Test {
    PaperhandVault vault;
    MockToken stock;
    MockToken ph;
    MockFeed feed;

    address owner = address(0xA11CE);
    address treasury = address(0x7EA);
    address alice = address(0xA1);
    address bob = address(0xB0);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant WAD = 1e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MockToken();
        ph = new MockToken();
        feed = new MockFeed(200e8); // $200.00

        vm.prank(owner);
        vault = new PaperhandVault(owner);

        vm.startPrank(owner);
        vault.setPenaltyRecipient(treasury);
        vault.setFeed(address(stock), address(feed), 4 days, true);
        vault.setPaperhand(address(ph));
        vm.stopPrank();

        stock.mint(alice, 1_000e18);
        ph.mint(alice, 100e18);
        vm.startPrank(alice);
        stock.approve(address(vault), type(uint256).max);
        ph.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _open(uint256 amount, uint256 lo, uint256 hi) internal returns (uint256 id) {
        vm.prank(alice);
        id = vault.open(address(stock), amount, lo, hi);
    }

    // ------------------------------------------------------------------ basics

    function test_open_mints_and_burns_the_fee() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        assertEq(vault.ownerOf(id), alice);
        assertEq(stock.balanceOf(address(vault)), 100e18);
        assertEq(ph.balanceOf(DEAD), 1e18, "fee burned");
        assertEq(vault.claimable(id), 0, "nothing released at the bottom");
    }

    function test_open_rejects_a_range_below_market() public {
        vm.prank(alice);
        vm.expectRevert(PaperhandVault.RangeBelowMarket.selector);
        vault.open(address(stock), 10e18, 150e18, 300e18);
    }

    function test_open_rejects_an_inverted_range() public {
        vm.prank(alice);
        vm.expectRevert(PaperhandVault.BadRange.selector);
        vault.open(address(stock), 10e18, 300e18, 300e18);
    }

    function test_open_rejects_a_token_with_no_feed() public {
        MockToken other = new MockToken();
        other.mint(alice, 10e18);
        vm.startPrank(alice);
        other.approve(address(vault), type(uint256).max);
        vm.expectRevert(PaperhandVault.NoPrice.selector);
        vault.open(address(other), 10e18, 300e18, 400e18);
        vm.stopPrank();
    }

    // --------------------------------------------------------------- the ladder

    function test_release_is_linear_across_the_range() public {
        uint256 id = _open(100e18, 200e18, 320e18);

        feed.set(260e8);                       // halfway
        vault.poke(id);
        assertEq(vault.claimable(id), 50e18);

        feed.set(290e8);                       // three quarters
        vault.poke(id);
        assertEq(vault.claimable(id), 75e18);

        feed.set(320e8);                       // the top
        vault.poke(id);
        assertEq(vault.claimable(id), 100e18);

        feed.set(900e8);                       // above the top changes nothing
        vault.poke(id);
        assertEq(vault.claimable(id), 100e18);
    }

    function test_high_water_never_gives_back() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vault.poke(id);
        feed.set(201e8);                       // crashes back down
        vault.poke(id);
        assertEq(vault.claimable(id), 50e18, "half stays released");
    }

    function test_poke_is_open_to_anyone() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vm.prank(bob);
        vault.poke(id);
        assertEq(vault.claimable(id), 50e18);
    }

    // -------------------------------------------------------------- withdrawals

    function test_claim_pays_only_the_new_slice() public {
        uint256 id = _open(100e18, 200e18, 320e18);

        feed.set(260e8);
        vm.prank(alice);
        assertEq(vault.claim(id), 50e18);
        assertEq(stock.balanceOf(alice), 900e18 + 50e18);

        feed.set(290e8);
        vm.prank(alice);
        assertEq(vault.claim(id), 25e18, "only the delta");
        assertEq(vault.claimable(id), 0);
    }

    function test_full_claim_burns_the_nft_and_leaves_no_dust() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(320e8);
        vm.prank(alice);
        vault.claim(id);
        assertEq(stock.balanceOf(address(vault)), 0, "vault emptied exactly");
        vm.expectRevert();
        vault.ownerOf(id);
    }

    function test_claim_reverts_when_nothing_moved() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        vm.prank(alice);
        vm.expectRevert(PaperhandVault.NothingToClaim.selector);
        vault.claim(id);
    }

    function test_only_the_holder_can_claim_or_close() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vm.startPrank(bob);
        vm.expectRevert(PaperhandVault.NotHolder.selector);
        vault.claim(id);
        vm.expectRevert(PaperhandVault.NotHolder.selector);
        vault.close(id);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- closing early

    function test_close_cuts_thirty_percent_of_what_is_still_locked() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);                       // half released
        vault.poke(id);

        (uint256 pr, uint256 pp) = vault.previewClose(id);
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);

        assertEq(penalty, 15e18, "30% of the 50 still locked");
        assertEq(returned, 85e18, "50 released plus 35 of the locked half");
        assertEq(returned, pr); assertEq(penalty, pp);
        assertEq(stock.balanceOf(treasury), 15e18);
        assertEq(stock.balanceOf(alice), 900e18 + 85e18);
        assertEq(stock.balanceOf(address(vault)), 0);
    }

    function test_close_after_a_partial_claim_still_balances() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vm.prank(alice);
        vault.claim(id);                       // took 50
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 15e18);
        assertEq(returned, 35e18);
        assertEq(stock.balanceOf(alice) + stock.balanceOf(treasury), 1_000e18);
    }

    function test_close_at_the_top_costs_nothing() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(320e8);
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 0);
        assertEq(returned, 100e18);
    }

    // ------------------------------------------------------- the oracle going dark

    function test_a_stale_feed_cannot_trap_a_deposit() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vault.poke(id);

        vm.warp(block.timestamp + 30 days);    // the feed stops answering
        assertFalse(_priceOk(), "price is unusable");

        vm.prank(alice);
        assertEq(vault.claim(id), 50e18, "claim still works off the stored mark");

        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 15e18);
        assertEq(returned, 35e18);
    }

    function test_a_reverting_feed_cannot_trap_a_deposit() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vault.poke(id);
        feed.setBroken(true);

        vault.poke(id);                        // no revert, simply no update
        vm.prank(alice);
        vault.close(id);
        assertEq(stock.balanceOf(address(vault)), 0);
    }

    function test_the_admin_delisting_a_token_cannot_trap_a_deposit() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vault.poke(id);

        vm.prank(owner);
        vault.setFeed(address(stock), address(feed), 4 days, false);

        vm.prank(alice);
        assertEq(vault.claim(id), 50e18);
        vm.prank(alice);
        vault.close(id);
    }

    function test_sequencer_down_blocks_new_vaults_but_not_withdrawals() public {
        MockFeed seq = new MockFeed(0);
        vm.prank(owner);
        vault.setSequencerUptimeFeed(address(seq));
        vm.warp(block.timestamp + 1 hours);    // past the grace period

        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vault.poke(id);

        seq.set(1);                            // sequencer reports down
        vm.prank(alice);
        vm.expectRevert(PaperhandVault.NoPrice.selector);
        vault.open(address(stock), 10e18, 300e18, 400e18);

        vm.prank(alice);
        assertEq(vault.claim(id), 50e18, "withdrawals keep working");
    }

    // ------------------------------------------------------------ the nft itself

    function test_sending_the_nft_sends_the_position() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);

        vm.prank(alice);
        vault.transferFrom(alice, bob, id);

        vm.prank(alice);
        vm.expectRevert(PaperhandVault.NotHolder.selector);
        vault.claim(id);

        vm.prank(bob);
        assertEq(vault.claim(id), 50e18);
        assertEq(stock.balanceOf(bob), 50e18);
    }

    function test_vaults_of_lists_what_a_holder_has() public {
        uint256 a = _open(10e18, 200e18, 320e18);
        uint256 b = _open(20e18, 210e18, 400e18);
        uint256[] memory ids = vault.vaultsOf(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], a); assertEq(ids[1], b);
    }

    // ------------------------------------------------------------- odd erc20s

    function test_a_fee_on_transfer_token_books_what_arrived() public {
        stock.setFee(100); // 1%
        uint256 id = _open(100e18, 200e18, 320e18);
        assertEq(stock.balanceOf(address(vault)), 99e18);

        feed.set(320e8);
        vm.prank(alice);
        uint256 got = vault.claim(id);
        assertEq(got, 99e18, "books the amount received, not the amount sent");
        assertEq(stock.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------- admin

    function test_admin_cannot_touch_deposits() public {
        _open(100e18, 200e18, 320e18);
        uint256 held = stock.balanceOf(address(vault));
        vm.startPrank(owner);
        vault.setCreationFee(0);
        vault.setRenderer(address(0xBEEF));
        vault.setSequencerUptimeFeed(address(0));
        vault.setFeed(address(stock), address(feed), 1 days, true);
        vm.stopPrank();
        assertEq(stock.balanceOf(address(vault)), held, "nothing moved");
    }

    function test_fee_is_capped_and_paperhand_is_set_once() public {
        vm.startPrank(owner);
        vm.expectRevert(PaperhandVault.FeeOutOfRange.selector);
        vault.setCreationFee(10_001e18);
        vm.expectRevert(PaperhandVault.FeeOutOfRange.selector);
        vault.setCreationFee(0.5e18);
        vault.setCreationFee(0);              // free is allowed
        vault.setCreationFee(10_000e18);      // the ceiling is allowed
        vm.expectRevert(PaperhandVault.AlreadySet.selector);
        vault.setPaperhand(address(0xBEEF));
        vm.stopPrank();
    }

    function test_outsiders_cannot_administer() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.setFeed(address(stock), address(feed), 1 days, true);
    }

    // --------------------------------------------------------------- royalties

    function test_royalties_point_at_the_treasury() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        (address to, uint256 owed) = vault.royaltyInfo(id, 10 ether);
        assertEq(to, treasury);
        assertEq(owed, 0.3 ether, "3% by default");
        assertTrue(vault.supportsInterface(0x2a55205a), "ERC-2981 announced");
        assertTrue(vault.supportsInterface(0x80ac58cd), "still an ERC-721");
    }

    function test_royalties_are_capped_at_five_percent() public {
        vm.startPrank(owner);
        vm.expectRevert(PaperhandVault.FeeOutOfRange.selector);
        vault.setRoyalty(501);
        vault.setRoyalty(500);
        vault.setRoyalty(0);                       // turning them off is allowed
        vm.stopPrank();
        (, uint256 owed) = vault.royaltyInfo(1, 10 ether);
        assertEq(owed, 0);
    }

    // ---------------------------------------------------------------- maturity

    function test_after_seven_hundred_days_closing_is_free() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        assertFalse(vault.matured(id));
        assertEq(vault.maturesAt(id), block.timestamp + 700 days);

        vm.warp(block.timestamp + 700 days - 1);
        feed.set(200e8);                           // the feed is alive and well
        (, uint256 stillCharged) = vault.previewClose(id);
        assertEq(stillCharged, 30e18, "a second early, still 30%");

        vm.warp(block.timestamp + 1);
        assertTrue(vault.matured(id));
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 0);
        assertEq(returned, 100e18, "the whole deposit walks out");
        assertEq(stock.balanceOf(treasury), 0);
    }

    function test_maturity_pays_out_even_with_a_dead_oracle() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.setBroken(true);
        vm.warp(block.timestamp + 700 days);
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 0);
        assertEq(returned, 100e18);
    }

    function test_maturity_is_per_vault_not_global() public {
        uint256 first = _open(50e18, 200e18, 320e18);
        vm.warp(block.timestamp + 400 days);
        feed.set(200e8);                          // the feed keeps publishing
        uint256 second = _open(50e18, 200e18, 320e18);
        vm.warp(block.timestamp + 301 days);      // 701 and 301 days old
        assertTrue(vault.matured(first));
        assertFalse(vault.matured(second));
    }

    // ------------------------------------------------------- the oracle dying

    function test_a_dead_feed_makes_closing_free_after_thirty_days() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.set(260e8);
        vault.poke(id);                            // half released, feed stamped

        feed.setBroken(true);
        vm.warp(block.timestamp + 29 days);
        vault.poke(id);                            // still tries, still nothing
        (, uint256 penalty29) = vault.previewClose(id);
        assertEq(penalty29, 15e18, "29 days in, the cut still applies");
        assertFalse(vault.oracleDead(address(stock)));

        vm.warp(block.timestamp + 2 days);
        assertTrue(vault.oracleDead(address(stock)));
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 0, "the feed died, not the user's nerve");
        assertEq(returned, 100e18);
        assertEq(stock.balanceOf(treasury), 0);
    }

    function test_a_healthy_feed_is_never_mistaken_for_a_dead_one() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        vm.warp(block.timestamp + 90 days);        // nobody touches it for months
        feed.set(260e8);                           // but the feed keeps publishing

        assertTrue(vault.oracleDead(address(stock)), "the stamp is old");
        assertFalse(vault.freeToClose(id), "but the feed answers, so nothing is free");
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 15e18, "closing reads the price first, so the cut stands");
        assertEq(returned, 85e18);
    }

    function test_delisting_a_token_still_frees_it_after_the_dead_line() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        vm.prank(owner);
        vault.setFeed(address(stock), address(feed), 4 days, false);
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        (uint256 returned, uint256 penalty) = vault.close(id);
        assertEq(penalty, 0);
        assertEq(returned, 100e18);
    }

    function test_re_enabling_a_feed_restarts_the_dead_line() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        feed.setBroken(true);
        vm.warp(block.timestamp + 31 days);
        assertTrue(vault.oracleDead(address(stock)));

        feed.setBroken(false);
        feed.set(260e8);
        vm.prank(owner);
        vault.setFeed(address(stock), address(feed), 4 days, true);
        assertFalse(vault.oracleDead(address(stock)), "the clock restarts");

        (, uint256 penalty) = vault.previewClose(id);
        assertEq(penalty, 30e18, "back to normal, nothing released yet");
    }

    // ---------------------------------------------------------------- treasury

    function test_no_vault_can_open_before_the_treasury_is_set() public {
        PaperhandVault fresh = new PaperhandVault(owner);
        vm.prank(owner);
        fresh.setFeed(address(stock), address(feed), 4 days, true);
        vm.startPrank(alice);
        stock.approve(address(fresh), type(uint256).max);
        vm.expectRevert(PaperhandVault.TreasuryNotSet.selector);
        fresh.open(address(stock), 10e18, 300e18, 400e18);
        vm.stopPrank();
    }

    function test_the_treasury_is_set_once_and_never_again() public {
        vm.prank(owner);
        vm.expectRevert(PaperhandVault.AlreadySet.selector);
        vault.setPenaltyRecipient(address(0xDEAD1));
        assertEq(vault.penaltyRecipient(), treasury);
    }

    // --------------------------------------------------------------- the terms

    function test_the_terms_of_a_vault_never_change() public {
        uint256 id = _open(100e18, 200e18, 320e18);
        (address tk,, uint128 dep,, uint128 lo, uint128 hi,) = vault.vaults(id);

        feed.set(260e8);
        vault.poke(id);
        vm.prank(alice);
        vault.claim(id);
        vm.prank(alice);
        vault.transferFrom(alice, bob, id);
        vm.prank(owner);
        vault.setCreationFee(10_000e18);       // admin moves everything it can

        (address tk2,, uint128 dep2,, uint128 lo2, uint128 hi2,) = vault.vaults(id);
        assertEq(tk, tk2); assertEq(dep, dep2); assertEq(lo, lo2); assertEq(hi, hi2);
    }

    function test_art_can_be_frozen_for_good() public {
        vm.startPrank(owner);
        vault.setRenderer(address(0xA47));
        vault.freezeArt();
        vm.expectRevert(PaperhandVault.AlreadySet.selector);
        vault.setRenderer(address(0xB00));
        vm.stopPrank();
        assertEq(vault.renderer(), address(0xA47));
    }

    // -------------------------------------------------------------------- fuzz

    /// @dev Whatever the path, every token that goes in comes out exactly once,
    ///      split between the holder and the treasury. Nothing is created or stuck.
    function testFuzz_conservation(uint96 amount, uint96 lowOff, uint96 span, uint96 move) public {
        amount = uint96(bound(amount, 1e12, 500e18));
        uint256 lo = 200e18 + bound(lowOff, 0, 300e18);
        uint256 hi = lo + bound(span, 1e18, 500e18);
        uint256 target = 200e18 + bound(move, 0, 1_500e18);

        stock.mint(alice, amount);
        uint256 before = stock.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.open(address(stock), amount, lo, hi);

        feed.set(int256(target / 1e10)); // WAD to the feed's 8 decimals
        vault.poke(id);

        if (vault.claimable(id) > 0) {
            vm.prank(alice);
            vault.claim(id);
        }
        if (vault.balanceOf(alice) > 0) {   // still open after the claim
            vm.prank(alice);
            vault.close(id);
        }

        assertEq(
            stock.balanceOf(alice) + stock.balanceOf(treasury),
            before,
            "every token accounted for"
        );
        assertEq(stock.balanceOf(address(vault)), 0, "vault left empty");
    }

    // ----------------------------------------------------------------- helpers

    function _priceOk() internal view returns (bool ok) {
        (ok, ) = vault.priceOrZero(address(stock));
    }
}
