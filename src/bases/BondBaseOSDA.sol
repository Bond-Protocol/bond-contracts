// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

import {IBondOSDA, IBondAuctioneer} from "../interfaces/IBondOSDA.sol";
import {IBondOracle} from "../interfaces/IBondOracle.sol";
import {IBondTeller} from "../interfaces/IBondTeller.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";

import {TransferHelper} from "../lib/TransferHelper.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title Bond Oracle-based Sequential Dutch Auctioneer (OSDA)
/// @notice Bond Oracle-based Sequential Dutch Auctioneer Base Contract
/// @dev Bond Protocol is a system to create bond markets for any token pair.
///      The markets do not require maintenance and will manage bond prices
///      based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Oracle-based Sequential Dutch Auctioneer contract allows users to create
///      and manage bond markets. All bond market data is stored in the Auctioneer.
///      The market price is based on an outside Oracle and varies based on whether the
///      market is under- or oversold with the goal of selling a target amount of
///      payout tokens or buying a target amount of quote tokens over the duration of
///      a market. An Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets.
///
/// @author Oighty
abstract contract BondBaseOSDA is IBondOSDA, Auth {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== ERRORS ========== */

    error Auctioneer_OnlyMarketOwner();
    error Auctioneer_InitialPriceLessThanMin();
    error Auctioneer_MarketNotActive();
    error Auctioneer_MaxPayoutExceeded();
    error Auctioneer_AmountLessThanMinimum();
    error Auctioneer_NotEnoughCapacity();
    error Auctioneer_InvalidCallback();
    error Auctioneer_BadExpiry();
    error Auctioneer_InvalidParams();
    error Auctioneer_NotAuthorized();
    error Auctioneer_NewMarketsNotAllowed();
    error Auctioneer_OraclePriceZero();

    /* ========== EVENTS ========== */

    event MarketCreated(
        uint256 indexed id,
        address indexed payoutToken,
        address indexed quoteToken,
        uint48 vesting
    );
    event MarketClosed(uint256 indexed id);
    event Tuned(uint256 indexed id, uint256 oldControlVariable, uint256 newControlVariable);

    /* ========== STATE VARIABLES ========== */

    /// @notice Main information pertaining to bond market
    mapping(uint256 => BondMarket) public markets;

    /// @notice Information used to control how a bond market changes
    mapping(uint256 => BondTerms) public terms;

    /// @notice New address to designate as market owner. They must accept ownership to transfer permissions.
    mapping(uint256 => address) public newOwners;

    /// @notice Whether or not the market creator is authorized to use a callback address
    mapping(address => bool) public callbackAuthorized;

    /// @notice Whether or not the auctioneer allows new markets to be created
    /// @dev    Changing to false will sunset the auctioneer after all active markets end
    bool public allowNewMarkets;

    // Minimum time parameter values. Can be updated by admin.
    /// @notice Minimum deposit interval for a market
    uint48 public minDepositInterval;

    /// @notice Minimum duration for a market
    uint48 public minMarketDuration;

    // A 'vesting' param longer than 50 years is considered a timestamp for fixed expiry.
    uint48 internal constant MAX_FIXED_TERM = 52 weeks * 50;
    uint48 internal constant ONE_HUNDRED_PERCENT = 100e3; // one percent equals 1000.

    // BondAggregator contract with utility functions
    IBondAggregator internal immutable _aggregator;

    // BondTeller contract that handles interactions with users and issues tokens
    IBondTeller internal immutable _teller;

    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) Auth(guardian_, authority_) {
        _aggregator = aggregator_;
        _teller = teller_;

        minDepositInterval = 1 hours;
        minMarketDuration = 1 days;

        allowNewMarkets = true;
    }

    /* ========== MARKET FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function createMarket(bytes calldata params_) external virtual returns (uint256);

    /// @notice core market creation logic, see IBondOSDA.MarketParams documentation
    function _createMarket(MarketParams memory params_) internal returns (uint256) {
        // Upfront permission and timing checks
        {
            // Check that the auctioneer is allowing new markets to be created
            if (!allowNewMarkets) revert Auctioneer_NewMarketsNotAllowed();
            // Restrict the use of a callback address unless allowed
            if (!callbackAuthorized[msg.sender] && params_.callbackAddr != address(0))
                revert Auctioneer_NotAuthorized();
            // Start time must be zero or in the future
            if (params_.start > 0 && params_.start < block.timestamp)
                revert Auctioneer_InvalidParams();
        }
        // Register new market on aggregator and get marketId
        uint256 marketId = _aggregator.registerMarket(params_.payoutToken, params_.quoteToken);

        // Set basic market data
        BondMarket storage market = markets[marketId];
        market.owner = msg.sender;
        market.quoteToken = params_.quoteToken;
        market.payoutToken = params_.payoutToken;
        market.callbackAddr = params_.callbackAddr;
        market.capacityInQuote = params_.capacityInQuote;
        market.capacity = params_.capacity;

        // Check that the base discount is in bounds (cannot be 100% or greater)
        BondTerms storage term = terms[marketId];
        if (
            params_.baseDiscount >= ONE_HUNDRED_PERCENT ||
            params_.baseDiscount > params_.maxDiscountFromCurrent
        ) revert Auctioneer_InvalidParams();
        term.baseDiscount = params_.baseDiscount;

        // Validate oracle and get price variables
        (uint256 price, uint256 oracleConversion, uint256 scale) = _validateOracle(
            marketId,
            params_.oracle,
            params_.quoteToken,
            params_.payoutToken,
            params_.baseDiscount
        );
        term.oracle = params_.oracle;
        term.oracleConversion = oracleConversion;
        term.scale = scale;

        // Check that the max discount from current price is in bounds (cannot be greater than 100%)
        if (params_.maxDiscountFromCurrent > ONE_HUNDRED_PERCENT) revert Auctioneer_InvalidParams();

        // Calculate the minimum price for the market
        term.minPrice = price.mulDivUp(
            uint256(ONE_HUNDRED_PERCENT - params_.maxDiscountFromCurrent),
            uint256(ONE_HUNDRED_PERCENT)
        );

        // Check time bounds
        if (
            params_.duration < minMarketDuration ||
            params_.depositInterval < minDepositInterval ||
            params_.depositInterval > params_.duration
        ) revert Auctioneer_InvalidParams();

        // Calculate the maximum payout amount for this market, determined by deposit interval
        uint256 capacity = params_.capacityInQuote
            ? params_.capacity.mulDiv(
                scale,
                price.mulDivUp(
                    uint256(ONE_HUNDRED_PERCENT - params_.baseDiscount),
                    uint256(ONE_HUNDRED_PERCENT)
                )
            )
            : params_.capacity;
        market.maxPayout = capacity.mulDiv(
            uint256(params_.depositInterval),
            uint256(params_.duration)
        );

        // Check target interval discount in bounds
        if (params_.targetIntervalDiscount > ONE_HUNDRED_PERCENT) revert Auctioneer_InvalidParams();

        // Calculate decay speed
        term.decaySpeed =
            (params_.duration * params_.targetIntervalDiscount) /
            params_.depositInterval;

        // Store bond time terms
        term.vesting = params_.vesting;
        uint48 start = params_.start == 0 ? uint48(block.timestamp) : params_.start;
        term.start = start;
        term.conclusion = start + params_.duration;

        // Emit market created event
        emit MarketCreated(
            marketId,
            address(params_.payoutToken),
            address(params_.quoteToken),
            params_.vesting
        );

        return marketId;
    }

    function _validateOracle(
        uint256 id_,
        IBondOracle oracle_,
        ERC20 quoteToken_,
        ERC20 payoutToken_,
        uint48 baseDiscount_
    )
        internal
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        // Ensure token decimals are in bounds
        uint8 payoutTokenDecimals = payoutToken_.decimals();
        uint8 quoteTokenDecimals = quoteToken_.decimals();

        if (payoutTokenDecimals < 6 || payoutTokenDecimals > 18) revert Auctioneer_InvalidParams();
        if (quoteTokenDecimals < 6 || quoteTokenDecimals > 18) revert Auctioneer_InvalidParams();

        // Check that oracle is valid. It should:
        // 1. Be a contract
        if (address(oracle_) == address(0) || address(oracle_).code.length == 0)
            revert Auctioneer_InvalidParams();

        // 2. Allow registering markets
        oracle_.registerMarket(id_, quoteToken_, payoutToken_);

        // 3. Return a valid price for the quote token : payout token pair
        uint256 currentPrice = oracle_.currentPrice(id_);
        if (currentPrice == 0) revert Auctioneer_OraclePriceZero();

        // 4. Return a valid decimal value for the quote token : payout token pair price
        uint8 oracleDecimals = oracle_.decimals(id_);
        if (oracleDecimals < 6 || oracleDecimals > 18) revert Auctioneer_InvalidParams();

        // Calculate scaling values for market:
        // 1. We need a value to convert between the oracle decimals to the bond market decimals
        // 2. We need the bond scaling value to convert between quote and payout tokens using the market price

        // Get the price decimals for the current oracle price
        // Oracle price is in quote tokens per payout token
        // E.g. if quote token is $10 and payout token is $2000,
        // then the oracle price is 200 quote tokens per payout token.
        // If the oracle has 18 decimals, then it would return 200 * 10^18.
        // In this case, the price decimals would be 2 since 200 = 2 * 10^2.
        // We apply the base discount to the oracle price before calculating
        // since this will be the initial equilibrium price of the market.
        int8 priceDecimals = _getPriceDecimals(
            currentPrice.mulDivUp(
                uint256(ONE_HUNDRED_PERCENT - baseDiscount_),
                uint256(ONE_HUNDRED_PERCENT)
            ),
            oracleDecimals
        );
        // Check price decimals in reasonable range
        // These bounds are quite large and it is unlikely any combination of tokens
        // will have a price difference larger than 10^24 in either direction.
        // Check that oracle decimals are large enough to avoid precision loss from negative price decimals
        if (int8(oracleDecimals) <= -priceDecimals || priceDecimals > 24)
            revert Auctioneer_InvalidParams();

        // Calculate the oracle price conversion factor
        // oraclePriceFactor = int8(oracleDecimals) + priceDecimals;
        // bondPriceFactor = 36 - priceDecimals / 2 + priceDecimals;
        // oracleConversion = 10^(bondPriceFactor - oraclePriceFactor);
        uint256 oracleConversion = 10**uint8(36 - priceDecimals / 2 - int8(oracleDecimals));

        // Unit to scale calculation for this market by to ensure reasonable values
        // for price, debt, and control variable without under/overflows.
        //
        // scaleAdjustment should be equal to (payoutDecimals - quoteDecimals) - ((payoutPriceDecimals - quotePriceDecimals) / 2)
        // scale = 10^(36 + scaleAdjustment);
        uint256 scale = 10 **
            uint8(36 + int8(payoutTokenDecimals) - int8(quoteTokenDecimals) - priceDecimals / 2);

        return (currentPrice * oracleConversion, oracleConversion, scale);
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

    /// @inheritdoc IBondOSDA
    function setMinMarketDuration(uint48 duration_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require duration to be greater than minimum deposit interval and at least 1 day
        if (duration_ < minDepositInterval || duration_ < 1 days) revert Auctioneer_InvalidParams();

        minMarketDuration = duration_;
    }

    /// @inheritdoc IBondOSDA
    function setMinDepositInterval(uint48 depositInterval_) external override requiresAuth {
        // Restricted to authorized addresses

        // Require min deposit interval to be less than minimum market duration and at least 1 hour
        if (depositInterval_ > minMarketDuration || depositInterval_ < 1 hours)
            revert Auctioneer_InvalidParams();

        minDepositInterval = depositInterval_;
    }

    // Unused, but required by interface
    function setIntervals(uint256 id_, uint32[3] calldata intervals_) external override {}

    // Unused, but required by interface
    function setDefaults(uint32[6] memory defaults_) external override {}

    /// @inheritdoc IBondAuctioneer
    function setAllowNewMarkets(bool status_) external override requiresAuth {
        /// Restricted to authorized addresses, initially restricted to guardian
        allowNewMarkets = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function setCallbackAuthStatus(address creator_, bool status_) external override requiresAuth {
        /// Restricted to authorized addresses, initially restricted to guardian
        callbackAuthorized[creator_] = status_;
    }

    /// @inheritdoc IBondAuctioneer
    function closeMarket(uint256 id_) external override {
        if (msg.sender != markets[id_].owner) revert Auctioneer_OnlyMarketOwner();
        _close(id_);
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
        BondTerms memory term = terms[id_];

        // If market uses a callback, check that owner is still callback authorized
        if (market.callbackAddr != address(0) && !callbackAuthorized[market.owner])
            revert Auctioneer_NotAuthorized();

        // Check if market is live, if not revert
        if (!isLive(id_)) revert Auctioneer_MarketNotActive();

        // Retrieve price and calculate payout
        uint256 price = marketPrice(id_);

        // Payout for the deposit = amount / price
        //
        // where:
        // payout = payout tokens out
        // amount = quote tokens in
        // price = quote tokens : payout token (i.e. 200 QUOTE : BASE), adjusted for scaling
        payout = amount_.mulDiv(term.scale, price);

        // Payout must be greater than user inputted minimum
        if (payout < minAmountOut_) revert Auctioneer_AmountLessThanMinimum();

        // Markets have a max payout amount, capping size because deposits
        // do not experience slippage. max payout is recalculated upon tuning
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
        unchecked {
            // Capacity is decreased by the deposited or paid amount
            market.capacity -= market.capacityInQuote ? amount_ : payout;

            // Markets keep track of how many quote tokens have been
            // purchased, and how many payout tokens have been sold
            market.purchased += amount_;
            market.sold += payout;
        }
    }

    /* ========== INTERNAL DEPO FUNCTIONS ========== */

    /// @notice          Close a market
    /// @dev             Closing a market sets capacity to 0 and immediately stops bonding
    function _close(uint256 id_) internal {
        terms[id_].conclusion = uint48(block.timestamp);
        markets[id_].capacity = 0;

        emit MarketClosed(id_);
    }

    /* ========== INTERNAL VIEW FUNCTIONS ========== */

    /// @notice             Calculate current market price of payout token in quote tokens
    /// @dev                See marketPrice() in IBondOSDA for explanation of price computation
    /// @param id_          Market ID
    /// @return             Price for market as a ratio of quote tokens to payout tokens with 36 decimals
    function _currentMarketPrice(uint256 id_) internal view returns (uint256) {
        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];

        // Get price from oracle, apply oracle conversion factor, and apply target discount
        uint256 price = (term.oracle.currentPrice(id_) * term.oracleConversion).mulDivUp(
            (ONE_HUNDRED_PERCENT - term.baseDiscount),
            ONE_HUNDRED_PERCENT
        );

        // Revert if price is 0
        if (price == 0) revert Auctioneer_OraclePriceZero();

        // Calculate initial capacity based on remaining capacity and amount sold/purchased up to this point
        uint256 initialCapacity = market.capacity +
            (market.capacityInQuote ? market.purchased : market.sold);

        // Compute seconds remaining until market will conclude
        uint256 conclusion = uint256(term.conclusion);
        uint256 timeRemaining = conclusion - block.timestamp;

        // Calculate expectedCapacity as the capacity expected to be bought or sold up to this point
        // Higher than current capacity means the market is undersold, lower than current capacity means the market is oversold
        uint256 expectedCapacity = initialCapacity.mulDiv(
            timeRemaining,
            conclusion - uint256(term.start)
        );

        // Price is increased or decreased based on how far the market is ahead or behind
        // Intuition:
        // If the time neutral capacity is higher than the initial capacity, then the market is undersold and price should be discounted
        // If the time neutral capacity is lower than the initial capacity, then the market is oversold and price should be increased
        //
        // This implementation uses a linear price decay
        // P(t) = P(0) * (1 + k * (X(t) - C(t) / C(0)))
        // P(t): price at time t
        // P(0): initial/target price of the market provided by oracle + base discount (see IOSDA.MarketParams)
        // k: decay speed of the market
        // k = L / I * d, where L is the duration/length of the market, I is the deposit interval, and d is the target interval discount.
        // X(t): expected capacity of the market at time t.
        // X(t) = C(0) * t / L.
        // C(t): actual capacity of the market at time t.
        // C(0): initial capacity of the market provided by the user (see IOSDA.MarketParams).
        uint256 adjustment;
        if (expectedCapacity > market.capacity) {
            adjustment =
                ONE_HUNDRED_PERCENT +
                (term.decaySpeed * (expectedCapacity - market.capacity)) /
                initialCapacity;
        } else {
            // If actual capacity is greater than expected capacity, we need to check for underflows
            // The adjustment has a minimum value of 0 since that will reduce the price to 0 as well.
            uint256 factor = (term.decaySpeed * (market.capacity - expectedCapacity)) /
                initialCapacity;
            adjustment = ONE_HUNDRED_PERCENT > factor ? ONE_HUNDRED_PERCENT - factor : 0;
        }

        return price.mulDivUp(adjustment, ONE_HUNDRED_PERCENT);
    }

    /* ========== INTERNAL VIEW FUNCTIONS ========== */

    /// @notice         Helper function to calculate number of price decimals based on the value returned from the price feed.
    /// @param price_   The price to calculate the number of decimals for
    /// @return         The number of decimals
    function _getPriceDecimals(uint256 price_, uint8 feedDecimals_) internal pure returns (int8) {
        int8 decimals;
        while (price_ >= 10) {
            price_ = price_ / 10;
            decimals++;
        }

        // Subtract the stated decimals from the calculated decimals to get the relative price decimals.
        // Required to do it this way vs. normalizing at the beginning since price decimals can be negative.
        return decimals - int8(feedDecimals_);
    }

    /* ========== EXTERNAL VIEW FUNCTIONS ========== */

    /// @inheritdoc IBondAuctioneer
    function getMarketInfoForPurchase(uint256 id_)
        external
        view
        override
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

    /// @inheritdoc IBondOSDA
    function marketPrice(uint256 id_) public view override returns (uint256) {
        uint256 price = _currentMarketPrice(id_);

        return (price > terms[id_].minPrice) ? price : terms[id_].minPrice;
    }

    /// @inheritdoc IBondAuctioneer
    function marketScale(uint256 id_) external view override returns (uint256) {
        return terms[id_].scale;
    }

    /// @inheritdoc IBondAuctioneer
    function payoutFor(
        uint256 amount_,
        uint256 id_,
        address referrer_
    ) public view override returns (uint256) {
        /// Calculate the payout for the given amount of tokens
        uint256 fee = amount_.mulDiv(_teller.getFee(referrer_), 1e5);
        uint256 payout = (amount_ - fee).mulDiv(terms[id_].scale, marketPrice(id_));

        /// Check that the payout is less than or equal to the maximum payout,
        /// Revert if not, otherwise return the payout
        if (payout > maxPayout(id_)) {
            revert Auctioneer_MaxPayoutExceeded();
        } else {
            return payout;
        }
    }

    /// @inheritdoc IBondOSDA
    function maxPayout(uint256 id_) public view override returns (uint256) {
        // Get current price
        uint256 price = marketPrice(id_);

        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];

        // Convert capacity to payout token units for comparison with max payout
        uint256 capacity = market.capacityInQuote
            ? market.capacity.mulDiv(term.scale, price)
            : market.capacity;

        // Cap max payout at the remaining capacity
        return market.maxPayout > capacity ? capacity : market.maxPayout;
    }

    /// @inheritdoc IBondAuctioneer
    function maxAmountAccepted(uint256 id_, address referrer_) external view returns (uint256) {
        // Calculate maximum amount of quote tokens that correspond to max bond size
        // Maximum of the maxPayout and the remaining capacity converted to quote tokens
        BondMarket memory market = markets[id_];
        BondTerms memory term = terms[id_];
        uint256 price = marketPrice(id_);
        uint256 quoteCapacity = market.capacityInQuote
            ? market.capacity
            : market.capacity.mulDiv(price, term.scale);
        uint256 maxQuote = market.maxPayout.mulDiv(price, term.scale);
        uint256 amountAccepted = quoteCapacity < maxQuote ? quoteCapacity : maxQuote;

        // Take into account teller fees and return
        // Estimate fee based on amountAccepted. Fee taken will be slightly larger than
        // this given it will be taken off the larger amount, but this avoids rounding
        // errors with trying to calculate the exact amount.
        // Therefore, the maxAmountAccepted is slightly conservative.
        uint256 estimatedFee = amountAccepted.mulDiv(
            _teller.getFee(referrer_),
            ONE_HUNDRED_PERCENT
        );

        return amountAccepted + estimatedFee;
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
