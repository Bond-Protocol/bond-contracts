// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

interface IBondOracle {
    /// @notice Register a new bond market on the oracle
    function registerMarket(
        uint256 id_,
        ERC20 quoteToken_,
        ERC20 payoutToken_
    ) external;

    /// @notice Returns the price as a ratio of quote tokens to base tokens for the provided market id scaled by 10^decimals
    function currentPrice(uint256 id_) external view returns (uint256);

    /// @notice Returns the price as a ratio of quote tokens to base tokens for the provided token pair scaled by 10^decimals
    function currentPrice(ERC20 quoteToken_, ERC20 payoutToken_) external view returns (uint256);

    /// @notice Returns the number of configured decimals of the price value for the provided market id
    function decimals(uint256 id_) external view returns (uint8);

    /// @notice Returns the number of configured decimals of the price value for the provided token pair
    function decimals(ERC20 quoteToken_, ERC20 payoutToken_) external view returns (uint8);
}
