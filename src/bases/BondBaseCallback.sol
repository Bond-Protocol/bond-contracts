// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {TransferHelper} from "../lib/TransferHelper.sol";

import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAggregator} from "../interfaces/IBondAggregator.sol";

/// @title Bond Callback
/// @notice Bond Callback Base Contract
/// @dev Bond Protocol is a system to create Olympus-style bond markets
///      for any token pair. The markets do not require maintenance and will manage
///      bond prices based on activity. Bond issuers create BondMarkets that pay out
///      a Payout Token in exchange for deposited Quote Tokens. Users can purchase
///      future-dated Payout Tokens with Quote Tokens at the current market price and
///      receive Bond Tokens to represent their position while their bond vests.
///      Once the Bond Tokens vest, they can redeem it for the Quote Tokens.
///
/// @dev The Callback contract is an optional feature of the Bond system.
///      Callbacks allow issuers (market creators) to apply custom logic on receipt and
///      payout of tokens. The Callback must be created prior to market creation and
///      the address passed in as an argument. The Callback depends on the Aggregator
///      contract for the Auctioneer that the market is created to get market data.
///
/// @dev Without a Callback contract, payout tokens are transferred directly from
///      the market owner on each bond purchase (market owners must approve the
///      Teller serving that market for the amount of Payout Tokens equivalent to the
///      capacity of a market when created.
///
/// @author Oighty, Zeus, Potted Meat, indigo
abstract contract BondBaseCallback is IBondCallback, Ownable, ReentrancyGuard {
    using TransferHelper for ERC20;

    /* ========== ERRORS ========== */

    error Callback_MarketNotSupported(uint256 id);
    error Callback_TokensNotReceived();
    error Callback_TellerMismatch();

    /* ========== STATE VARIABLES ========== */

    mapping(address => mapping(uint256 => bool)) public approvedMarkets;
    mapping(uint256 => uint256[2]) internal _amountsPerMarket;
    mapping(ERC20 => uint256) internal priorBalances;
    IBondAggregator internal _aggregator;

    /* ========== CONSTRUCTOR ========== */

    constructor(IBondAggregator aggregator_) {
        _aggregator = aggregator_;
    }

    /* ========== WHITELISTING ========== */

    /// @inheritdoc IBondCallback
    function whitelist(address teller_, uint256 id_) external override onlyOwner {
        // Check that the market id is a valid, live market on the aggregator
        try _aggregator.isLive(id_) returns (bool live) {
            if (!live) revert Callback_MarketNotSupported(id_);
        } catch {
            revert Callback_MarketNotSupported(id_);
        }

        // Check that the provided teller is the teller for the market ID on the stored aggregator
        // We could pull the teller from the aggregator, but requiring the teller to be passed in
        // is more explicit about which contract is being whitelisted
        if (teller_ != address(_aggregator.getTeller(id_))) revert Callback_TellerMismatch();

        approvedMarkets[teller_][id_] = true;
    }

    /// @notice Remove a market ID on a teller from the whitelist
    /// @dev    Shutdown function in case there's an issue with the teller
    /// @param  teller_ Address of the Teller contract which serves the market
    /// @param  id_     ID of the market to remove from whitelist
    function blacklist(address teller_, uint256 id_) external onlyOwner {
        // Check that the teller matches the aggregator provided teller for the market ID
        if (teller_ != address(_aggregator.getTeller(id_))) revert Callback_TellerMismatch();

        // Remove market from whitelist
        approvedMarkets[teller_][id_] = false;
    }

    /* ========== CALLBACK ========== */

    /// @inheritdoc IBondCallback
    function callback(
        uint256 id_,
        uint256 inputAmount_,
        uint256 outputAmount_
    ) external override nonReentrant {
        /// Confirm that the teller and market id are whitelisted
        if (!approvedMarkets[msg.sender][id_]) revert Callback_MarketNotSupported(id_);

        // Get tokens for market
        (, , ERC20 payoutToken, ERC20 quoteToken, , ) = _aggregator
            .getAuctioneer(id_)
            .getMarketInfoForPurchase(id_);

        // Check that quoteTokens were transferred prior to the call
        if (quoteToken.balanceOf(address(this)) < priorBalances[quoteToken] + inputAmount_)
            revert Callback_TokensNotReceived();

        // Call internal _callback function to handle implementation-specific logic
        /// @dev must implement _callback in contracts that inherit this base
        _callback(id_, quoteToken, inputAmount_, payoutToken, outputAmount_);

        // Store amounts in/out
        /// @dev updated after internal call so previous balances are available to check against
        priorBalances[quoteToken] = quoteToken.balanceOf(address(this));
        priorBalances[payoutToken] = payoutToken.balanceOf(address(this));
        _amountsPerMarket[id_][0] += inputAmount_;
        _amountsPerMarket[id_][1] += outputAmount_;
    }

    /// @notice              Implementation-specific callback logic
    /// @dev                 Must be implemented by inheriting contract. Called from callback.
    /// @param id_           ID of the market
    /// @param quoteToken_   Address of the market quote token
    /// @param inputAmount_  Amount of quote tokens expected to have been sent to the callback
    /// @param payoutToken_    Address of the market payout token
    /// @param outputAmount_ Amount of payout tokens to be paid out
    function _callback(
        uint256 id_,
        ERC20 quoteToken_,
        uint256 inputAmount_,
        ERC20 payoutToken_,
        uint256 outputAmount_
    ) internal virtual;

    /// @inheritdoc IBondCallback
    function amountsForMarket(uint256 id_)
        external
        view
        override
        returns (uint256 in_, uint256 out_)
    {
        uint256[2] memory marketAmounts = _amountsPerMarket[id_];
        return (marketAmounts[0], marketAmounts[1]);
    }

    /// @notice         Withdraw tokens from the callback and update balances
    /// @notice         Only callback owner
    /// @param to_      Address of the recipient
    /// @param token_   Address of the token to withdraw
    /// @param amount_  Amount of tokens to withdraw
    function withdraw(
        address to_,
        ERC20 token_,
        uint256 amount_
    ) external onlyOwner {
        token_.safeTransfer(to_, amount_);
        priorBalances[token_] = token_.balanceOf(address(this));
    }

    /// @notice         Deposit tokens to the callback and update balances
    /// @notice         Only callback owner
    /// @param token_   Address of the token to deposit
    /// @param amount_  Amount of tokens to deposit
    function deposit(ERC20 token_, uint256 amount_) external onlyOwner {
        token_.safeTransferFrom(msg.sender, address(this), amount_);
        priorBalances[token_] = token_.balanceOf(address(this));
    }
}
