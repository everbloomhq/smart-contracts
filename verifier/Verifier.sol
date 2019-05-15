pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {Common} from "../Common.sol";

/// An abstract Contract of Verifier.
contract Verifier is Common {

    /// Verifies trade for KYC purposes.
    /// @param order Order object.
    /// @param takerAmountToFill Desired amount of takerToken to sell.
    /// @param taker Taker address.
    /// @return Whether the trade is valid.
    function verify(
        Order memory order,
        uint256 takerAmountToFill,
        address taker
    )
    public
    view
    returns (bool);

    /// Verifies user address for KYC purposes.
    /// @param user User address.
    /// @return Whether the user address is valid.
    function verifyUser(address user)
    external
    view
    returns (bool);
}