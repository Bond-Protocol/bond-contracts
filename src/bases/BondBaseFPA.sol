/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/src/auth/Auth.sol";

import {IBondFPA, IBondAuctioneer} from "../interfaces/IBondFPA.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";
import {IWrapper} from "../interfaces/IWrapper.sol";

import {TransferHelper} from "../lib/TransferHelper.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title Bond Fixed Price Auctioneer
/// @notice Bond Fixed Price Auctioneer Base Contract
/// @dev Bond Protocol is a system to create markets for any token pair.
///      Bond issuers create BondMarkets that pay out a Payout Token in exchange
///      for deposited Quote Tokens. Users can purchase future-dated Payout Tokens
///      with Quote Tokens at the current market price and receive Bond Tokens to
///      represent their position while their bond vests. Once the Bond Tokens vest,
///      they can redeem it for the Quote Tokens. Alternatively, markets can be
///      instant swap and payouts are made immediately to the user.
///
/// @dev An Auctioneer contract allows users to create and manage bond markets.
///      All bond pricing logic and market data is stored in the Auctioneer.
///      An Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets. The Fixed Price Auctioneer
///      lets issuers set a Fixed Price to buy a target amount of quote tokens or sell
///      a target amount of payout tokens over the duration of a market.
///      See IBondFPA.sol for price format details.
///
/// @author Oighty
abstract contract BondBaseFPA is IBondFPA, Auth {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== ERRORS ========== */

    error Auctioneer_OnlyMarketOwner();
    error Auctioneer_MarketNotActive();
    error Auctioneer_MaxPayoutExceeded();
    error Auctioneer_AmountLessThanMinimum();
    error Auctioneer_NotEnoughCapacity();
    error Auctioneer_InvalidCallback();
    error Auctioneer_BadExpiry();
    error Auctioneer_InvalidParams();
    error Auctioneer_NotAuthorized();
    error Auctioneer_NewMarketsNotAllowed();

    /* ========== EVENTS ========== */

    event MarketCreated(
        uint256 indexed id,
        address indexed payoutToken,
        address indexed quoteToken,
        uint48 vesting,
        uint256 fixedPrice
    );
    event MarketClosed(uint256 indexed id);

    /* ========== STATE VARIABLES ========== */

    /// @notice Information pertaining to bond markets
    mapping(uint256 => BondMarket) public markets;

    /// @notice Information pertaining to market vesting and duration
    mapping(uint256 => BondTerms) public terms;

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    /// @notice Whether or not the auctioneer allows new markets to be created
    /// @dev    Changing to false will sunset the auctioneer after all active markets end
    bool public allowNewMarkets;

    // Minimum time parameter values. Can be updated by admin.
    /// @notice Minimum deposit interval for a market
    uint48 public minDepositInterval;

    /// @notice Minimum market duration in seconds
    uint48 public minMarketDuration;

    /// @notice Whether or not the market creator is authorized to use a callback address
    mapping(address => bool) public callbackAuthorized;

    // A 'vesting' param longer than 50 years is considered a timestamp for fixed expiry.
    uint48 internal constant MAX_FIXED_TERM = 52 weeks * 50;
    uint48 internal constant ONE_HUNDRED_PERCENT = 1e5; // one percent equals 1000.

    // BondAggregator contract with utility functions
    IBondAggregator internal immutable _aggregator;

    // BondTeller contract that handles interactions with users and issues tokens
    IBondTeller internal immutable _teller;

    // Wrapper contract that handles deposits and withdrawals in native tokens
    IWrapper internal immutable _wrapper;

    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_,
        IWrapper wrapper_
    ) Auth(guardian_, authority_) {
        _aggregator = aggregator_;
        _teller = teller_;
        _wrapper = wrapper_;

        minDepositInterval = 1 hours;
        minMarketDuration = 1 days;

        allowNewMarkets = true;
    }

    /* ========== MARKET FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function createMarket(bytes calldata params_) external payable virtual returns (uint256);

    /// @notice core market creation logic, see IBondFPA.MarketParams documentation
    function _createMarket(MarketParams memory params_) internal returns (uint256) {
        {
            // Check that the auctioneer is allowing new markets to be created
            if (!allowNewMarkets) revert Auctioneer_NewMarketsNotAllowed();

            // Convert native payout token to wrapped token
            if (params_.payoutToken == ERC20(address(0))) {
                // If capacity is in quote tokens, cannot safely convert to wrapped token
                if (params_.capacityInQuote) revert Auctioneer_InvalidParams();

                // Ensure capacity is equal to the value sent
                if (params_.capacity != msg.value) revert Auctioneer_InvalidParams();

                _wrapper.deposit{value: msg.value}();
                params_.payoutToken = ERC20(address(_wrapper));
            }

            // Ensure params are in bounds
            uint8 payoutTokenDecimals = params_.payoutToken.decimals();
            uint8 quoteTokenDecimals = params_.quoteToken.decimals();

            if (payoutTokenDecimals < 6 || payoutTokenDecimals > 18) revert Auctioneer_InvalidParams();
            if (quoteTokenDecimals < 6 || quoteTokenDecimals > 18) revert Auctioneer_InvalidParams();
            if (params_.scaleAdjustment < -24 || params_.scaleAdjustment > 24) revert Auctioneer_InvalidParams();

            // Restrict the use of a callback address unless allowed
            if (!callbackAuthorized[msg.sender] && params_.callbackAddr != address(0))
                revert Auctioneer_NotAuthorized();

            // Start time must be zero or in the future
            if (params_.start > 0 && params_.start < block.timestamp) revert Auctioneer_InvalidParams();
        }

        // Unit to scale calculation for this market by to ensure reasonable values.
        // See IBondFPA for more details.
        //
        // scaleAdjustment should be equal to (payoutDecimals - quoteDecimals) - ((payoutPriceDecimals - quotePriceDecimals) / 2)
        uint256 scale;
        unchecked {
            scale = 10 ** uint8(36 + params_.scaleAdjustment);
        }

        // Check that price is not zero
        if (params_.formattedPrice == 0) revert Auctioneer_InvalidParams();

        // Check time bounds
        if (
            params_.duration < minMarketDuration ||
            params_.depositInterval < minDepositInterval ||
            params_.depositInterval > params_.duration
        ) revert Auctioneer_InvalidParams();

        // Calculate the maximum payout amount for this market
        uint256 _maxPayout = (
            params_.capacityInQuote ? params_.capacity.mulDiv(scale, params_.formattedPrice) : params_.capacity
        ).mulDiv(uint256(params_.depositInterval), uint256(params_.duration));

        // Register new market on aggregator and get marketId
        uint256 marketId = _aggregator.registerMarket(params_.payoutToken, params_.quoteToken);

        markets[marketId] = BondMarket({
            owner: msg.sender,
            payoutToken: params_.payoutToken,
            quoteToken: params_.quoteToken,
            callbackAddr: params_.callbackAddr,
            capacityInQuote: params_.capacityInQuote,
            capacity: params_.capacity,
            maxPayout: _maxPayout,
            price: params_.formattedPrice,
            scale: scale,
            purchased: 0,
            sold: 0
        });

        // Calculate and store time terms
        uint48 start = params_.start == 0 ? uint48(block.timestamp) : params_.start;

        terms[marketId] = BondTerms({start: start, conclusion: start + params_.duration, vesting: params_.vesting});

        emit MarketCreated(
            marketId,
            address(params_.payoutToken),
            address(params_.quoteToken),
            params_.vesting,
            params_.formattedPrice
        );

        return marketId;
    }

    /// @inheritdoc IBondAuctioneer
    function pushOwnership(uint256 id_, address newOwner_) external override {
        if (msg.sender != markets[id_].owner) revert Auctioneer_OnlyMarketOwner();
        newOwners[id_] = newOwner_;
    }

    /// @inheritdoc IBondAuctioneer
    function pullOwnership(uint256 id_) external override {
        if (msg.sender != newOwners[id_]) revert Auctioneer_NotAuthorized();
        markets[id_].owner = newOwners[id_];
    }

    /// @inheritdoc IBondFPA
    function setMinMarketDuration(uint48 duration_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require duration to be greater than minimum deposit interval and at least 1 day
        if (duration_ < minDepositInterval || duration_ < 1 days) revert Auctioneer_InvalidParams();

        minMarketDuration = duration_;
    }

    /// @inheritdoc IBondFPA
    function setMinDepositInterval(uint48 depositInterval_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require min deposit interval to be less than minimum market duration and at least 1 hour
        if (depositInterval_ > minMarketDuration || depositInterval_ < 1 hours) revert Auctioneer_InvalidParams();

        minDepositInterval = depositInterval_;
    }

    // Unused, but required by interface
    function setIntervals(uint256 id_, uint32[3] calldata intervals_) external override {}

    // Unused, but required by interface
    function setDefaults(uint32[6] memory defaults_) external override {}

    /// @inheritdoc IBondAuctioneer
    function setAllowNewMarkets(bool status_) external override requiresAuth {
        // Restricted to authorized addresses
        allowNewMarkets = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function setCallbackAuthStatus(address creator_, bool status_) external override requiresAuth {
        // Restricted to authorized addresses
        callbackAuthorized[creator_] = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function closeMarket(uint256 id_) external override {
        if (msg.sender != markets[id_].owner) revert Auctioneer_OnlyMarketOwner();
        terms[id_].conclusion = uint48(block.timestamp);
        markets[id_].capacity = 0;

        emit MarketClosed(id_);
    }

    /* ========== TELLER FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function purchaseBond(
        uint256 id_,
        uint256 amount_,
        uint256 minAmountOut_
    ) external override returns (uint256 payout) {
        if (msg.sender != address(_teller)) revert Auctioneer_NotAuthorized();

        BondMarket storage market = markets[id_];

        // If market uses a callback, check that owner is still callback authorized
        if (market.callbackAddr != address(0) && !callbackAuthorized[market.owner]) revert Auctioneer_NotAuthorized();

        // Check if market is live, if not revert
        if (!isLive(id_)) revert Auctioneer_MarketNotActive();

        // Calculate payout amount from fixed price
        payout = amount_.mulDiv(market.scale, market.price);

        // Payout must be greater than user inputted minimum
        if (payout < minAmountOut_) revert Auctioneer_AmountLessThanMinimum();

        // Markets have a max payout amount per transaction
        if (payout > market.maxPayout) revert Auctioneer_MaxPayoutExceeded();

        // Update Capacity

        // Capacity is either the number of payout tokens that the market can sell
        // (if capacity in quote is false),
        //
        // or the number of quote tokens that the market can buy
        // (if capacity in quote is true)

        // If amount/payout is greater than capacity remaining, revert
        if (market.capacityInQuote ? amount_ > market.capacity : payout > market.capacity)
            revert Auctioneer_NotEnoughCapacity();
        // Capacity is decreased by the deposited or paid amount
        market.capacity -= market.capacityInQuote ? amount_ : payout;

        // Markets keep track of how many quote tokens have been
        // purchased, and how many payout tokens have been sold
        market.purchased += amount_;
        market.sold += payout;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /* ========== EXTERNAL VIEW FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function getMarketInfoForPurchase(
        uint256 id_
    )
        external
        view
        returns (
            address owner,
            address callbackAddr,
            ERC20 payoutToken,
            ERC20 quoteToken,
            uint48 vesting,
            uint256 maxPayout_
        )
    {
        BondMarket memory market = markets[id_];
        return (
            market.owner,
            market.callbackAddr,
            market.payoutToken,
            market.quoteToken,
            terms[id_].vesting,
            maxPayout(id_)
        );
    }

    /// @inheritdoc IBondAuctioneer
    function marketPrice(uint256 id_) public view override returns (uint256) {
        return markets[id_].price;
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(uint256 id_) external view override returns (uint256) {
        return markets[id_].scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(uint256 amount_, uint256 id_, address referrer_) public view override returns (uint256) {
        // Calculate the payout for the given amount of tokens
        uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), ONE_HUNDRED_PERCENT);
        uint256 payout = (amount_ - fee).mulDiv(markets[id_].scale, marketPrice(id_));

        // Check that the payout is less than or equal to the maximum payout,
        // Revert if not, otherwise return the payout
        if (payout > maxPayout(id_)) {
            revert Auctioneer_MaxPayoutExceeded();
        } else {
            return payout;
        }
    }

    /// @inheritdoc IBondAuctioneer
    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        BondMarket memory market = markets[id_];
        uint256 price = marketPrice(id_);
        uint256 quoteCapacity = market.capacityInQuote ? market.capacity : market.capacity.mulDiv(price, market.scale);
        uint256 maxQuote = market.maxPayout.mulDiv(price, market.scale);
        uint256 amountAccepted = quoteCapacity < maxQuote ? quoteCapacity : maxQuote;

        // Take into account teller fees and return
        // Estimate fee based on amountAccepted. Fee taken will be slightly larger than
        // this given it will be taken off the larger amount, but this avoids rounding
        // errors with trying to calculate the exact amount.
        // Therefore, the maxAmountAccepted is slightly conservative.
        uint256 estimatedFee = amountAccepted.mulDiv(_teller.getFee(referrer_), ONE_HUNDRED_PERCENT);

        return amountAccepted + estimatedFee;
    }

    /// @inheritdoc IBondFPA
    function maxPayout(uint256 id_) public view override returns (uint256) {
        // Get current price
        uint256 price = marketPrice(id_);

        BondMarket memory market = markets[id_];

        // Convert capacity to payout token units for comparison with max payout
        uint256 capacity = market.capacityInQuote ? market.capacity.mulDiv(market.scale, price) : market.capacity;

        // Cap max payout at the remaining capacity
        return market.maxPayout > capacity ? capacity : market.maxPayout;
    }

    /// @inheritdoc IBondAuctioneer
    function isInstantSwap(uint256 id_) public view returns (bool) {
        uint256 vesting = terms[id_].vesting;
        return (vesting <= MAX_FIXED_TERM) ? vesting == 0 : vesting <= block.timestamp;
    }

    /// @inheritdoc IBondAuctioneer
    function isLive(uint256 id_) public view override returns (bool) {
        return (markets[id_].capacity != 0 &&
            terms[id_].conclusion > uint48(block.timestamp) &&
            terms[id_].start <= uint48(block.timestamp));
    }

    /// @inheritdoc IBondAuctioneer
    function ownerOf(uint256 id_) external view override returns (address) {
        return markets[id_].owner;
    }

    /// @inheritdoc IBondAuctioneer
    function getTeller() external view override returns (IBondTeller) {
        return _teller;
    }

    /// @inheritdoc IBondAuctioneer
    function getAggregator() external view override returns (IBondAggregator) {
        return _aggregator;
    }

    /// @inheritdoc IBondAuctioneer
    function currentCapacity(uint256 id_) external view override returns (uint256) {
        return markets[id_].capacity;
    }
}
