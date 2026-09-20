// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Draws the NFT card. Art only: it is handed the vault data and returns a string.
interface IVaultRenderer {
    function tokenURI(address vault, uint256 id) external view returns (string memory);
}

/// @title PaperhandVault
/// @notice Lock a whitelisted token behind a price range. It unlocks linearly as the
///         Chainlink price climbs from `priceLow` to `priceHigh`, and the unlock
///         ratchets on a high water mark, so a price that falls back never re-locks
///         what was already released. Each vault is an ERC-721: the holder claims,
///         closes or sells the position. Closing before the range is done costs a
///         flat 30% of the part still locked, which funds PAPERHAND buybacks.
///
/// @dev    Design notes that matter more than the code:
///
///         1. The oracle is only ever read to move the high water mark UP. Claiming,
///            closing and pricing a payout all run off stored state. A feed that is
///            stale, paused, disabled or permanently dead can never trap a deposit
///            and can never revert a withdrawal. Only opening a new vault needs a
///            live price, and there reverting is the correct answer.
///
///         1b. If a feed stays silent for thirty days, closing vaults on that token
///            stops costing anything. Every read of a usable price stamps the feed,
///            and closing stamps it too, so a healthy feed can never be mistaken
///            for a dead one.
///
///         2. There is no admin path to user funds. The owner manages the whitelist,
///            the creation fee and the art. Nothing else. Once the whitelist is set,
///            ownership can be renounced and the contract is frozen forever.
///
///         3. The penalty address and the burn address are immutable. Where the money
///            goes is decided at deployment and cannot be changed afterwards.
contract PaperhandVault is ERC721Enumerable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ---------------------------------------------------------------- constants

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    /// @notice Flat cut on the still locked part when closing early. Fixed at deployment.
    uint256 public constant PENALTY_BPS = 3_000;
    /// @notice Ceiling on the resale royalty. 5%, and it can only ever go down.
    uint96 public constant MAX_ROYALTY_BPS = 500;
    /// @notice Fee bounds. The fee is either zero, meaning vaults are free, or a
    ///         value inside this band. The ceiling is what stops an admin from
    ///         pricing everyone out by setting an absurd fee.
    uint256 public constant MIN_CREATION_FEE = 1e18;
    uint256 public constant MAX_CREATION_FEE = 10_000e18;
    /// @notice A vault this old can be closed with no penalty at all. It is the
    ///         backstop for a range the market never reaches: wait it out and the
    ///         deposit comes back whole.
    uint256 public constant MATURITY = 700 days;
    /// @notice A feed silent this long counts as dead, and closing a vault on that
    ///         token becomes free. The penalty exists to price impatience, not to
    ///         tax someone whose oracle stopped answering.
    uint256 public constant ORACLE_DEAD_AFTER = 30 days;
    /// @notice Creation fees go here. Unreachable, so the fee is a burn.
    address public constant FEE_SINK = 0x000000000000000000000000000000000000dEaD;
    /// @notice Delay after the L2 sequencer restarts before a price is trusted again.
    uint256 public constant SEQUENCER_GRACE = 30 minutes;

    // ------------------------------------------------------------------ storage

    struct Feed {
        address aggregator;
        uint32 maxStaleness; // stock feeds go quiet all weekend, budget for it
        uint8 decimals;
        bool enabled;
        uint40 lastPriceAt; // last time anyone read a usable price out of it
    }

    struct Vault {
        address token;
        uint64 createdAt;
        uint128 deposited; // what the contract actually received
        uint128 withdrawn; // what has already gone back to the holder
        uint128 priceLow; // WAD, nothing unlocks at or below
        uint128 priceHigh; // WAD, everything unlocks at or above
        uint128 highWater; // WAD, highest price this vault has ever seen
    }

    mapping(address token => Feed) public feeds;
    mapping(uint256 id => Vault) public vaults;
    uint256 public nextVaultId = 1;

    /// @notice Where early exit penalties land. Settable once, then permanent.
    ///         No vault can be opened before it is set, so a penalty can never
    ///         be stranded with nowhere to go.
    address public penaltyRecipient;

    /// @notice PAPERHAND, burned to open a vault. Settable once so the vault can ship first.
    IERC20 public paperhand;
    /// @notice How much PAPERHAND a vault costs. Capped by MAX_CREATION_FEE.
    uint256 public creationFee = 1e18;
    /// @notice Chainlink L2 sequencer uptime feed. Zero disables the check.
    address public sequencerUptimeFeed;
    /// @notice Optional art contract. Zero falls back to a plain metadata blob.
    address public renderer;
    /// @notice Once true the art can never be repointed again.
    bool public artFrozen;
    /// @notice Resale royalty, paid to the same treasury the penalties fund.
    uint96 public royaltyBps = 300;

    // ------------------------------------------------------------------- events

    event VaultOpened(
        uint256 indexed id,
        address indexed owner,
        address indexed token,
        uint256 amount,
        uint256 priceLow,
        uint256 priceHigh,
        uint256 priceAtOpen
    );
    event HighWaterRaised(uint256 indexed id, uint256 highWater);
    event Claimed(uint256 indexed id, address indexed to, uint256 amount);
    event Closed(uint256 indexed id, address indexed to, uint256 returned, uint256 penalty);
    event FeedSet(address indexed token, address aggregator, uint32 maxStaleness, bool enabled);
    event PaperhandSet(address token);
    event PenaltyRecipientSet(address recipient);
    event ArtFrozen();
    event RoyaltySet(uint96 bps);
    event CreationFeeSet(uint256 fee);
    event SequencerFeedSet(address feed);
    event RendererSet(address renderer);

    // ------------------------------------------------------------------- errors

    error NotHolder();
    error TokenNotAllowed();
    error BadRange();
    error RangeBelowMarket();
    error ZeroAmount();
    error NothingToClaim();
    error NoPrice();
    error AlreadySet();
    error FeeOutOfRange();
    error TreasuryNotSet();
    error ZeroAddress();
    error Overflow();

    constructor(address owner_) ERC721("Paperhand Vault", "PHVAULT") Ownable(owner_) {}

    // ------------------------------------------------------------------ opening

    /// @notice Lock `amount` of `token`, unlocking linearly from `priceLow` to `priceHigh`.
    ///         Mints the vault NFT to the caller.
    /// @param priceLow  WAD USD price where unlocking starts. Must be at or above market.
    /// @param priceHigh WAD USD price where the vault is fully unlocked.
    function open(address token, uint256 amount, uint256 priceLow, uint256 priceHigh)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (penaltyRecipient == address(0)) revert TreasuryNotSet();
        if (amount == 0) revert ZeroAmount();
        if (priceLow == 0 || priceHigh <= priceLow || priceHigh > type(uint128).max) revert BadRange();

        (bool ok, uint256 market) = _price(token); // also enforces the whitelist
        if (!ok) revert NoPrice();
        if (priceLow < market) revert RangeBelowMarket();
        feeds[token].lastPriceAt = uint40(block.timestamp);

        _burnFee();

        uint256 received = _pull(token, amount);
        if (received > type(uint128).max) revert Overflow();

        id = nextVaultId++;
        vaults[id] = Vault({
            token: token,
            createdAt: uint64(block.timestamp),
            deposited: uint128(received),
            withdrawn: 0,
            priceLow: uint128(priceLow),
            priceHigh: uint128(priceHigh),
            highWater: uint128(market)
        });
        _safeMint(msg.sender, id);

        emit VaultOpened(id, msg.sender, token, received, priceLow, priceHigh, market);
    }

    // ------------------------------------------------------------------ ratchet

    /// @notice Pull the current price in and raise this vault's high water mark.
    ///         Anyone can call it, for anyone's vault. It can only ever move up,
    ///         and it is a no-op when the feed has nothing new or nothing usable.
    function poke(uint256 id) public {
        _requireOwned(id);
        _sync(vaults[id], id);
    }

    function _sync(Vault storage v, uint256 id) internal {
        (bool ok, uint256 p) = _price(v.token);
        if (!ok) return;
        // proof of life for the feed, which is what the dead oracle escape reads
        feeds[v.token].lastPriceAt = uint40(block.timestamp);
        if (p > v.highWater && p <= type(uint128).max) {
            v.highWater = uint128(p);
            emit HighWaterRaised(id, p);
        }
    }

    // ----------------------------------------------------------------- withdraw

    /// @notice Take everything the price has released so far. Holder only.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        if (_ownerOf(id) != msg.sender) revert NotHolder();
        Vault storage v = vaults[id];

        _sync(v, id);
        amount = _claimable(v);
        if (amount == 0) revert NothingToClaim();

        v.withdrawn += uint128(amount);
        address token = v.token;
        if (v.withdrawn == v.deposited) _burn(id); // the vault is spent

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Close the vault now. The released part comes back whole, the rest
    ///         loses 30%, unless the vault has matured, in which case it all comes
    ///         back and the cut is zero.
    /// @dev    Runs entirely off stored state, so it works even if the oracle never
    ///         answers again. It still tries to ratchet first, so a holder closing
    ///         after a rally gets credit for it.
    function close(uint256 id) external nonReentrant returns (uint256 returned, uint256 penalty) {
        if (_ownerOf(id) != msg.sender) revert NotHolder();
        Vault storage v = vaults[id];

        _sync(v, id);

        uint256 released = _claimable(v);
        uint256 locked = uint256(v.deposited) - v.withdrawn - released;
        penalty = _free(v) ? 0 : (locked * PENALTY_BPS) / BPS;
        returned = released + locked - penalty;

        address token = v.token;
        v.withdrawn = v.deposited;
        _burn(id);

        if (penalty != 0) IERC20(token).safeTransfer(penaltyRecipient, penalty);
        if (returned != 0) IERC20(token).safeTransfer(msg.sender, returned);
        emit Closed(id, msg.sender, returned, penalty);
    }

    // ----------------------------------------------------------------- read-only

    /// @notice Current oracle price of `token`, WAD. Reverts when there is none.
    function price(address token) external view returns (uint256) {
        (bool ok, uint256 p) = _price(token);
        if (!ok) revert NoPrice();
        return p;
    }

    /// @notice Same read, but it answers instead of reverting.
    function priceOrZero(address token) external view returns (bool ok, uint256 p) {
        return _price(token);
    }

    /// @notice Share of the vault released so far, WAD, from the stored high water mark.
    function releasedFraction(uint256 id) public view returns (uint256) {
        return _fraction(vaults[id]);
    }

    /// @notice What the holder can take right now.
    function claimable(uint256 id) external view returns (uint256) {
        if (_ownerOf(id) == address(0)) return 0;
        return _claimable(vaults[id]);
    }

    /// @notice What closing right now pays out and costs.
    function previewClose(uint256 id) external view returns (uint256 returned, uint256 penalty) {
        if (_ownerOf(id) == address(0)) return (0, 0);
        Vault storage v = vaults[id];
        uint256 released = _claimable(v);
        uint256 locked = uint256(v.deposited) - v.withdrawn - released;
        penalty = _free(v) ? 0 : (locked * PENALTY_BPS) / BPS;
        returned = released + locked - penalty;
    }

    /// @notice When this vault stops charging anything to close. Past this, the
    ///         whole deposit walks out whatever the price did.
    function maturesAt(uint256 id) external view returns (uint256) {
        return uint256(vaults[id].createdAt) + MATURITY;
    }

    /// @notice True once closing costs nothing, for either reason.
    function freeToClose(uint256 id) external view returns (bool) {
        return _free(vaults[id]);
    }

    /// @notice True once the vault is old enough for a free close.
    function matured(uint256 id) external view returns (bool) {
        return block.timestamp >= uint256(vaults[id].createdAt) + MATURITY;
    }

    /// @notice True when this token's feed has been silent past the dead line.
    ///         Closing a vault on it is free while this holds.
    function oracleDead(address token) external view returns (bool) {
        return _oracleDead(token);
    }

    /// @notice Last time anyone pulled a usable price out of this token's feed.
    function feedLastPriceAt(address token) external view returns (uint256) {
        return feeds[token].lastPriceAt;
    }

    /// @notice ERC-2981. Marketplaces read this to know what a resale owes and to
    ///         whom. It is a declaration, not an enforcement: a venue is free to
    ///         ignore it, and several do. The receiver is the treasury, so a vault
    ///         sold on rather than closed still feeds the buyback.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (penaltyRecipient, (salePrice * royaltyBps) / BPS);
    }

    function supportsInterface(bytes4 id) public view override(ERC721Enumerable) returns (bool) {
        return id == 0x2a55205a || super.supportsInterface(id); // ERC-2981
    }

    /// @notice Every open vault a holder has, in one call.
    function vaultsOf(address holder) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(holder);
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = tokenOfOwnerByIndex(holder, i);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        address art = renderer;
        if (art != address(0)) return IVaultRenderer(art).tokenURI(address(this), id);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(string.concat(
                '{"name":"Paperhand Vault #', id.toString(),
                '","description":"A Paperhand vault. It releases its deposit as the price climbs through the range."}'
            )))
        );
    }

    // ----------------------------------------------------------------- internals

    function _fraction(Vault storage v) internal view returns (uint256) {
        uint256 mark = v.highWater;
        if (mark <= v.priceLow) return 0;
        if (mark >= v.priceHigh) return WAD;
        return ((mark - v.priceLow) * WAD) / (uint256(v.priceHigh) - v.priceLow);
    }

    /// @dev Two ways out with no cut: the vault is old enough, or the feed it
    ///      depends on has stopped answering for long enough. Both are read only
    ///      from stored state, so neither can be blocked by a broken oracle.
    function _free(Vault storage v) internal view returns (bool) {
        if (block.timestamp >= uint256(v.createdAt) + MATURITY) return true;
        if (!_oracleDead(v.token)) return false;
        // silent for a month is only half the test: the feed has to still be
        // unusable right now, so a quiet market never reads as a dead oracle
        (bool ok,) = _price(v.token);
        return !ok;
    }

    function _oracleDead(address token) internal view returns (bool) {
        uint256 last = feeds[token].lastPriceAt;
        return last != 0 && block.timestamp > last + ORACLE_DEAD_AFTER;
    }

    function _claimable(Vault storage v) internal view returns (uint256) {
        uint256 released = (uint256(v.deposited) * _fraction(v)) / WAD;
        uint256 withdrawn = v.withdrawn;
        return released > withdrawn ? released - withdrawn : 0;
    }

    /// @dev Never reverts. A missing, stale, paused or broken feed reads as "no price".
    function _price(address token) internal view returns (bool, uint256) {
        Feed memory f = feeds[token];
        if (!f.enabled) return (false, 0);
        if (!_sequencerUp()) return (false, 0);

        try AggregatorV3Interface(f.aggregator).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt == 0) return (false, 0);
            if (block.timestamp - updatedAt > f.maxStaleness) return (false, 0);
            return (true, (uint256(answer) * WAD) / (10 ** f.decimals));
        } catch {
            return (false, 0);
        }
    }

    function _sequencerUp() internal view returns (bool) {
        address seq = sequencerUptimeFeed;
        if (seq == address(0)) return true;
        try AggregatorV3Interface(seq).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            // 0 up, 1 down. A fresh restart is not trusted until the grace period passes.
            return answer == 0 && startedAt != 0 && block.timestamp - startedAt > SEQUENCER_GRACE;
        } catch {
            return false;
        }
    }

    function _burnFee() internal {
        IERC20 ph = paperhand;
        uint256 fee = creationFee;
        if (address(ph) == address(0) || fee == 0) return;
        ph.safeTransferFrom(msg.sender, FEE_SINK, fee);
    }

    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        received = t.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
    }

    // --------------------------------------------------------------------- admin
    // Nothing below can move, seize, unlock or redirect a deposit.

    /// @notice Whitelist a token and bind it to its Chainlink feed.
    /// @param maxStaleness How old a price may be. Stock feeds stop for the weekend,
    ///        so give them at least four days. Crypto feeds can be tight.
    function setFeed(address token, address aggregator, uint32 maxStaleness, bool enabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        uint8 dec;
        if (enabled) {
            if (aggregator == address(0)) revert ZeroAddress();
            dec = AggregatorV3Interface(aggregator).decimals();
        }
        // starting the clock at now means a feed that never worked still takes the
        // full dead line to unlock free exits, rather than opening them instantly
        feeds[token] = Feed({
            aggregator: aggregator,
            maxStaleness: maxStaleness,
            decimals: dec,
            enabled: enabled,
            lastPriceAt: enabled ? uint40(block.timestamp) : feeds[token].lastPriceAt
        });
        emit FeedSet(token, aggregator, maxStaleness, enabled);
    }

    /// @notice Bind PAPERHAND. One way, so the fee asset can never be swapped out.
    function setPaperhand(address token) external onlyOwner {
        if (address(paperhand) != address(0)) revert AlreadySet();
        if (token == address(0)) revert ZeroAddress();
        paperhand = IERC20(token);
        emit PaperhandSet(token);
    }

    /// @notice Set what a vault costs. Zero makes them free, any other value has to
    ///         sit between one and ten thousand PAPERHAND.
    function setCreationFee(uint256 fee) external onlyOwner {
        if (fee != 0 && (fee < MIN_CREATION_FEE || fee > MAX_CREATION_FEE)) revert FeeOutOfRange();
        creationFee = fee;
        emit CreationFeeSet(fee);
    }

    /// @notice Point the penalties at the treasury. One way: after this the
    ///         destination is fixed forever.
    function setPenaltyRecipient(address treasury) external onlyOwner {
        if (penaltyRecipient != address(0)) revert AlreadySet();
        if (treasury == address(0)) revert ZeroAddress();
        penaltyRecipient = treasury;
        emit PenaltyRecipientSet(treasury);
    }

    function setSequencerUptimeFeed(address feed) external onlyOwner {
        sequencerUptimeFeed = feed;
        emit SequencerFeedSet(feed);
    }

    function setRenderer(address art) external onlyOwner {
        if (artFrozen) revert AlreadySet();
        renderer = art;
        emit RendererSet(art);
    }

    /// @notice Set the resale royalty, between zero and 5%.
    function setRoyalty(uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert FeeOutOfRange();
        royaltyBps = bps;
        emit RoyaltySet(bps);
    }

    /// @notice Lock the art for good. After this the cards are as immutable as the
    ///         terms they draw.
    function freezeArt() external onlyOwner {
        artFrozen = true;
        emit ArtFrozen();
    }
}
