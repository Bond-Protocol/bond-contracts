// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IBondAuctioneer} from "../interfaces/IBondAuctioneer.sol";
import {IBondOracle} from "../interfaces/IBondOracle.sol";

interface IBondOFDA is IBondAuctioneer {
    /// @notice Basic token and capacity information for a bond market
    struct BondMarket {
        address owner; // market owner. sends payout tokens, receives quote tokens (defaults to creator)
        ERC20 payoutToken; // token to pay depositors with
        ERC20 quoteToken; // token to accept as payment
        address callbackAddr; // address to call for any operations on bond purchase. Must inherit to IBondCallback.
        bool capacityInQuote; // capacity limit is in payment token (true) or in payout (false, default)
        uint256 capacity; // capacity remaining
        uint256 maxPayout; // max payout tokens out in one order
        uint256 sold; // payout tokens out
        uint256 purchased; // quote tokens in
    }

    /// @notice Information pertaining to pricing and time parameters for a market
    struct BondTerms {
        IBondOracle oracle; // address to call for reference price. Must implement IBondOracle.
        uint48 start; // timestamp when market starts
        uint48 conclusion; // timestamp when market no longer offered
        uint48 vesting; // length of time from deposit to expiry if fixed-term, vesting timestamp if fixed-expiry
        uint48 fixedDiscount; // fixed discount percent for the market
        uint256 minPrice; // minimum price (hard floor for the market)
        uint256 scale; // scaling factor for the market (see MarketParams struct)
        uint256 oracleConversion; // conversion factor for oracle -> market price
    }

    /// @notice             Parameters to create a new bond market
    /// @param params_      Encoded bytes array, with the following elements
    /// @dev                    0. Payout Token (token paid out)
    /// @dev                    1. Quote Token (token to be received)
    /// @dev                    2. Callback contract address, should conform to IBondCallback. If 0x00, tokens will be transferred from market.owner
    /// @dev                    3. Oracle contract address, should conform to IBondOracle.
    /// @dev                    4. Fixed discount with 3 decimals of precision, e.g. 10_000 = 10%. Percent to reduce oracle price by to calculate market price.
    /// @dev                    5. Maximum discount from current oracle price with 3 decimals of precision, sets absolute minimum price for market
    /// @dev                    6. Is Capacity in Quote Token?
    /// @dev                    7. Capacity (amount in the decimals of the token chosen to provided capacity in).
    /// @dev                    8. Deposit interval (seconds). Desired frequency of bonds. Used to calculate max payout of market (maxPayout = length / depositInterval * capacity)
    /// @dev                    9. Is fixed term ? Vesting length (seconds) : Vesting expiry (timestamp).
    /// @dev                        A 'vesting' param longer than 50 years is considered a timestamp for fixed expiry.
    /// @dev                    10. Start Time of the Market (timestamp) - Allows starting a market in the future.
    /// @dev                        If a start time is provided, the txn must be sent prior to the start time (functions as a deadline).
    /// @dev                        If start time is not provided (i.e. 0), the market will start immediately.
    /// @dev                    11. Market Duration (seconds) - Duration of the market in seconds.
    struct MarketParams {
        ERC20 payoutToken;
        ERC20 quoteToken;
        address callbackAddr;
        IBondOracle oracle;
        uint48 fixedDiscount;
        uint48 maxDiscountFromCurrent;
        bool capacityInQuote;
        uint256 capacity;
        uint48 depositInterval;
        uint48 vesting;
        uint48 start;
        uint48 duration;
    }

    /// @notice Set the minimum market duration
    /// @notice Access controlled
    /// @param duration_ Minimum market duration in seconds
    function setMinMarketDuration(uint48 duration_) external;

    /// @notice Set the minimum deposit interval
    /// @notice Access controlled
    /// @param depositInterval_ Minimum deposit interval in seconds
    function setMinDepositInterval(uint48 depositInterval_) external;

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice             Calculate current market price of payout token in quote tokens
    /// @param id_          ID of market
    /// @return             Price for market in configured decimals (see MarketParams)
    /// @dev price is derived from the equation:
    //
    // p = max(min_p, o_p * (1 - d))
    //
    // where
    // p = price
    // min_p = minimum price
    // o_p = oracle price
    // d = fixed discount
    //
    // if price is below minimum price, minimum price is returned
    function marketPrice(uint256 id_) external view override returns (uint256);

    /// @notice             Calculate max payout of the market in payout tokens
    /// @dev                Returns a dynamically calculated payout or the maximum set by the creator, whichever is less.
    /// @param id_          ID of market
    /// @return             Current max payout for the market in payout tokens
    function maxPayout(uint256 id_) external view returns (uint256);
}
