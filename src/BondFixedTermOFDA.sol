// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.15;

import {BondBaseOFDA, IBondAggregator, Authority} from "./bases/BondBaseOFDA.sol";
import {IBondTeller} from "./interfaces/IBondTeller.sol";

/// @title Bond Fixed-Term Fixed Discount Auctioneer
/// @notice Bond Fixed-Term Fixed Discount Auctioneer Contract
/// @dev Bond Protocol is a permissionless system to create bond markets
///      for any token pair. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev An Auctioneer contract allows users to create and manage bond markets.
///      All bond pricing logic and market data is stored in the Auctioneer.
///      An Auctioneer is dependent on a Teller to serve external users and
///      an Aggregator to register new markets. The Fixed Discount Auctioneer
///      lets issuers set a Fixed Discount to an oracle price to buy a
///      target amount of quote tokens or sell a target amount of payout tokens
///      over the duration of a market.
///      See IBondOFDA.sol for price format details.
///
/// @dev The Fixed-Term Fixed Discount Auctioneer is an implementation of the
///      Bond Bas Fixed Discount Auctioneer contract specific to creating bond markets where
///      purchases vest in a fixed amount of time after purchased (rounded to the day).
///
/// @author Oighty
contract BondFixedTermOFDA is BondBaseOFDA {
    /* ========== CONSTRUCTOR ========== */
    constructor(
        IBondTeller teller_,
        IBondAggregator aggregator_,
        address guardian_,
        Authority authority_
    ) BondBaseOFDA(teller_, aggregator_, guardian_, authority_) {}

    /* ========== MARKET FUNCTIONS ========== */
    /// @inheritdoc BondBaseOFDA
    function createMarket(bytes calldata params_) external override returns (uint256) {
        // Decode params into the struct type expected by this auctioneer
        MarketParams memory params = abi.decode(params_, (MarketParams));

        // Check that the vesting parameter is valid for a fixed-term market
        if (params.vesting != 0 && (params.vesting < 1 days || params.vesting > MAX_FIXED_TERM))
            revert Auctioneer_InvalidParams();

        // Create market and return market ID
        return _createMarket(params);
    }
}
