pragma solidity ^0.5.7;

import {IBank} from "./IBank.sol";

/// Bank utility tools to query values by batch. (DeltaBalances alternative)
contract BankUtil {

    /// Gets multiple token deposit balances in a single request.
    /// @param bankAddr Bank address.
    /// @param user User address.
    /// @param tokens Array of token addresses.
    /// @return balances Array of token deposit balances.
    function depositedBalances(address bankAddr, address user, address[] calldata tokens) external view returns (uint[] memory balances) {
        balances = new uint[](tokens.length);
        IBank bank = IBank(bankAddr);
        for (uint i = 0; i < tokens.length; i++) {
            balances[i] = bank.balanceOf(tokens[i], user);
        }
        return balances;
    }
}