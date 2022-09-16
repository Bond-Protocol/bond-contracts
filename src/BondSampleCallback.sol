// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {BondBaseCallback} from "./bases/BondBaseCallback.sol";
import {IBondAggregator} from "./interfaces/IBondAggregator.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";

/// @title Bond Callback
/// @notice Bond Callback Sample Contract
/// @dev Bond Protocol is a permissionless system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Sample Callback is an implementation of the Base Callback contract that
///      checks if quote tokens have been passed in and transfers payout tokens from the
///      contract.
///
/// @author Oighty, Zeus, Potted Meat, indigo
contract BondSampleCallback is BondBaseCallback {
    using TransferHelper for ERC20;

    /* ========== CONSTRUCTOR ========== */

    constructor(IBondAggregator aggregator_) BondBaseCallback(aggregator_) {}

    /* ========== CALLBACK ========== */

    /// @inheritdoc BondBaseCallback
    function _callback(
        uint256 id_,
        ERC20 quoteToken_,
        uint256 inputAmount_,
        ERC20 payoutToken_,
        uint256 outputAmount_
    ) internal override {
        // Transfer new payoutTokens to sender
        payoutToken_.safeTransfer(msg.sender, outputAmount_);
    }
}
