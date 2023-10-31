/// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";
import {TransferHelper} from "src/lib/TransferHelper.sol";
import {FullMath} from "src/lib/FullMath.sol";
import {IBondAggregator} from "src/interfaces/IBondAggregator.sol";
import {IBondAuctioneer} from "src/interfaces/IBondAuctioneer.sol";
import {IBondTeller} from "src/interfaces/IBondTeller.sol";

contract LimitOrders is Auth {
    using TransferHelper for ERC20;
    using FullMath for uint256;

    /* ========== EVENTS ========== */
    event OrderExecuted(bytes32 digest);
    event OrderCancelled(bytes32 digest);
    event OrderReinstated(bytes32 digest);

    /* ========== ERRORS ========== */
    error LimitOrders_NotAuthorized();
    error LimitOrders_OrderExpired(uint256 deadline);
    error LimitOrders_MarketClosed(uint256 marketId);
    error LimitOrders_AlreadyExecuted(bytes32 digest);
    error LimitOrders_OrderCancelled(bytes32 digest);
    error LimitOrders_InvalidUpdate();
    error LimitOrders_InvalidFee(uint256 fee, uint256 maxFee);
    error LimitOrders_InvalidSignature(bytes signature);
    error LimitOrders_InvalidParams();
    error LimitOrders_InvalidUser();

    /* ========== STATE ========== */

    struct Order {
        uint256 marketId;
        address recipient;
        address referrer;
        uint256 amount;
        uint256 minAmountOut;
        uint256 maxFee;
        uint256 submitted;
        uint256 deadline;
        address user;
    }

    enum Status {
        Open,
        Executed,
        Cancelled
    }

    IBondAggregator public immutable aggregator;

    uint256 public chainId;
    bytes32 internal domainSeparator;

    bytes32 internal constant ORDER_TYPEHASH =
        keccak256(
            "Order(uint256 marketId,address recipient,address referrer,uint256 amount,uint256 minAmountOut,uint256 maxFee,uint256 submitted,uint256 deadline,address user)"
        );

    mapping(bytes32 => Status) public orderStatus;

    /* ========== CONSTRUCTOR ========== */

    constructor(IBondAggregator aggregator_, Authority authority_) Auth(address(0), authority_) {
        aggregator = aggregator_;
        chainId = block.chainid;
        domainSeparator = computeDomainSeparator();
    }

    /* ========== ORDER EXECUTION ========== */

    function executeOrders(
        Order[] calldata orders_,
        bytes[] calldata signatures_,
        uint256[] calldata fees_
    ) external requiresAuth {
        uint256 len = orders_.length;
        if (len != fees_.length || len != signatures_.length) revert LimitOrders_InvalidParams();

        for (uint256 i; i < len; ) {
            _executeOrder(orders_[i], signatures_[i], fees_[i]);
            unchecked {
                ++i;
            }
        }
    }

    function executeOrder(
        Order calldata order_,
        bytes calldata signature_,
        uint256 fee_
    ) external requiresAuth {
        _executeOrder(order_, signature_, fee_);
    }

    function _executeOrder(
        Order calldata order_,
        bytes calldata signature_,
        uint256 fee_
    ) internal {
        // Validate order
        bytes32 digest = _validateOrder(order_, signature_);

        // Validate that the order has not expired
        if (order_.deadline < block.timestamp) revert LimitOrders_OrderExpired(order_.deadline);

        // Validate that the market is still active
        if (!aggregator.isLive(order_.marketId)) revert LimitOrders_MarketClosed(order_.marketId);

        // Validate that the order has not already been executed
        // and that the user has not cancelled the order
        Status status = orderStatus[digest];
        if (status == Status.Executed) revert LimitOrders_AlreadyExecuted(digest);
        if (status == Status.Cancelled) revert LimitOrders_OrderCancelled(digest);

        // Confirm that executor fee is within bounds and calculate amount minus fee
        if (fee_ > order_.maxFee) revert LimitOrders_InvalidFee(fee_, order_.maxFee);
        uint256 amount = order_.amount - fee_;

        // Mark the order as executed
        orderStatus[digest] = Status.Executed;

        // Get max amount accepted for market
        uint256 maxAccepted = aggregator.maxAmountAccepted(order_.marketId, order_.referrer);

        // Set the amount for the purchase as the lesser of the order amount and the max accepted
        uint256 minAmountOut = order_.minAmountOut;
        if (amount > maxAccepted) {
            // If amount is too large, set to max accepted
            amount = maxAccepted;

            // We need to convert the new amount to an equivalent payout amount
            // The minAmountOut represents the price the user is willing to pay per token
            // after the max fee is taken out.
            if (minAmountOut != 0) {
                uint256 scale = aggregator.marketScale(order_.marketId);
                uint256 maxPrice = (order_.amount - order_.maxFee).mulDiv(
                    scale,
                    order_.minAmountOut
                );
                minAmountOut = amount.mulDiv(scale, maxPrice);
            }
        }

        // Transfer tokens from user to this contract for the purchase
        IBondAuctioneer auctioneer = aggregator.getAuctioneer(order_.marketId);
        (, , , ERC20 quoteToken, , ) = auctioneer.getMarketInfoForPurchase(order_.marketId);
        quoteToken.safeTransferFrom(order_.user, address(this), amount + fee_);

        // Approve teller to spend token
        IBondTeller teller = auctioneer.getTeller();
        quoteToken.safeApprove(address(teller), amount);

        // Execute purchase
        teller.purchase(order_.recipient, order_.referrer, order_.marketId, amount, minAmountOut);

        // Transfer fee to executor
        quoteToken.safeTransfer(msg.sender, fee_);

        // Emit event for off-chain service to pick up
        emit OrderExecuted(digest);
    }

    function _validateOrder(Order calldata order_, bytes calldata signature_)
        internal
        view
        returns (bytes32)
    {
        // Validate the user is not the zero address (must do this to avoid bypassing the signer check)
        // Although, transfers from the zero address would later fail in _executeOrder, so it may not be necessary
        if (order_.user == address(0)) revert LimitOrders_InvalidUser();
        if (signature_.length != 65) revert LimitOrders_InvalidSignature(signature_);

        // Get order digest
        bytes32 digest = getDigest(order_);

        // Validate signature
        bytes32 r = bytes32(signature_[0:32]);
        bytes32 s = bytes32(signature_[32:64]);
        uint8 v = uint8(signature_[64]);
        address signer = ecrecover(digest, v, r, s);

        if (signer != order_.user) revert LimitOrders_InvalidSignature(signature_);

        return digest;
    }

    function getDigest(Order calldata order_) public view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            ORDER_TYPEHASH,
                            order_.marketId,
                            order_.recipient,
                            order_.referrer,
                            order_.amount,
                            order_.minAmountOut,
                            order_.maxFee,
                            order_.submitted,
                            order_.deadline,
                            order_.user
                        )
                    )
                )
            );
    }

    /* ========== USER FUNCTIONS ========== */

    function cancelOrder(Order calldata order_) external {
        // Validate that the sender is the order "user"
        if (msg.sender != order_.user) revert LimitOrders_NotAuthorized();

        // Validate that the order has not expired (no need to cancel if so)
        if (order_.deadline < block.timestamp) revert LimitOrders_OrderExpired(order_.deadline);

        // Get order digest
        bytes32 digest = getDigest(order_);

        // Validate that the order has not already been executed
        // and that the user has not cancelled the order
        if (orderStatus[digest] != Status.Open) revert LimitOrders_InvalidUpdate();

        // Set order status to cancelled
        orderStatus[digest] = Status.Cancelled;

        // Emit event to pick up with off-chain service
        emit OrderCancelled(digest);
    }

    function reinstateOrder(Order calldata order_) external {
        // Validate that the sender is the order "user"
        if (msg.sender != order_.user) revert LimitOrders_NotAuthorized();

        // Validate that the order has not expired
        if (order_.deadline < block.timestamp) revert LimitOrders_OrderExpired(order_.deadline);

        // Get order digest
        bytes32 digest = getDigest(order_);

        // Validate that the order is currently cancelled
        if (orderStatus[digest] != Status.Cancelled) revert LimitOrders_InvalidUpdate();

        // Set the order status as open
        orderStatus[digest] = Status.Open;
    }

    /* ========== DOMAIN SEPARATOR ========== */

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == chainId ? domainSeparator : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256("Bond Protocol Limit Orders"),
                    keccak256("v1.0.0"),
                    block.chainid,
                    address(this)
                )
            );
    }

    function updateDomainSeparator() external {
        require(block.chainid != chainId, "DOMAIN_SEPARATOR_ALREADY_UPDATED");

        chainId = block.chainid;

        domainSeparator = computeDomainSeparator();
    }
}
