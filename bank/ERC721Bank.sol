pragma solidity ^0.5.7;

import {Authorizable} from "../lib/Authorizable.sol";
import {LibBytes} from "../lib/LibBytes.sol";
import {ReentrancyGuard} from "../lib/ReentrancyGuard.sol";
import {IBank} from "./IBank.sol";

// Simple ERC721 interface.
contract IERC721 {
    function ownerOf(uint256 _tokenId) external view returns (address);

    function transferFrom(address _from, address _to, uint256 _tokenId) external;

    function transfer(address _to, uint256 _tokenId) external;

    function getApproved(uint256 _tokenId) external view returns (address);
}

/// A bank locks ERC721 tokens. It doesn't contain any exchange logics that helps upgrade the exchange contract.
/// Users have complete control over their assets. Only user trusted contracts are able to access the assets.
contract ERC721Bank is IBank, Authorizable, ReentrancyGuard {

    using LibBytes for bytes;

    mapping(address => mapping(address => uint256[])) public deposits;

    event Deposit(address token, address user, uint256 tokenId, uint256[] balance);
    event Withdraw(address token, address user, uint256 tokenId, uint256[] balance);
    event TransferFallback(address token);

    /// Checks whether the user has enough deposit.
    /// @param token Token address.
    /// @param user User address.
    /// @param data Additional token data (e.g. tokenId for ERC721).
    /// @return Whether the user has enough deposit.
    function hasDeposit(address token, address user, uint256, bytes memory data) public view returns (bool) {
        for (uint256 i = 0; i < deposits[token][user].length; i++) {
            if (data.readUint256(0) == deposits[token][user][i]) {
                return true;
            }
        }
        return false;
    }

    /// Checks token balance available to use (including user deposit amount + user approved allowance amount).
    /// @param token Token address.
    /// @param user User address.
    /// @param data Additional token data (e.g. tokenId for ERC721).
    /// @return Token amount available.
    function getAvailable(address token, address user, bytes calldata data) external view returns (uint256) {
        uint256 tokenId = data.readUint256(0);
        if ((IERC721(token).getApproved(tokenId) == address(this) && IERC721(token).ownerOf(tokenId) == user) ||
            this.hasDeposit(token, user, 1, data)) {
            return 1;
        }
        return 0;
    }

    /// Gets balance of user's deposit.
    /// @param token Token address.
    /// @param user User address.
    /// @return Token deposit amount.
    function balanceOf(address token, address user) public view returns (uint256) {
        return deposits[token][user].length;
    }

    /// Gets an array of ERC721 tokenIds owned by user in deposit.
    /// @param token Token address.
    /// @param user User address.
    function getTokenIds(address token, address user) external view returns (uint256[] memory) {
        return deposits[token][user];
    }

    /// Deposits token from user wallet to bank.
    /// @param token Token address.
    /// @param user User address (allows third-party give tokens to any users).
    /// @param data Additional token data (e.g. tokenId for ERC721).
    function deposit(address token, address user, uint256, bytes calldata data) external nonReentrant payable {
        uint256 tokenId = data.readUint256(0);
        IERC721(token).transferFrom(msg.sender, address(this), tokenId);
        deposits[token][user].push(tokenId);
        emit Deposit(token, user, tokenId, deposits[token][user]);
    }

    /// Withdraws token from bank to user wallet.
    /// @param token Token address.
    /// @param data Additional token data (e.g. tokenId for ERC721).
    function withdraw(address token, uint256, bytes calldata data) external nonReentrant {
        uint256 tokenId = data.readUint256(0);
        require(hasDeposit(token, msg.sender, tokenId, data), "INSUFFICIENT_DEPOSIT");
        removeToken(token, msg.sender, tokenId);
        transferFallback(token, msg.sender, tokenId);
        emit Withdraw(token, msg.sender, tokenId, deposits[token][msg.sender]);
    }

    /// Transfers token from one address to another address.
    /// Only caller who are double-approved by both bank owner and token owner can invoke this function.
    /// @param token Token address.
    /// @param from The current token owner address.
    /// @param to The new token owner address.
    /// @param amount Token amount.
    /// @param data Additional token data (e.g. tokenId for ERC721).
    /// @param fromDeposit True if use fund from bank deposit. False if use fund from user wallet.
    /// @param toDeposit True if deposit fund to bank deposit. False if send fund to user wallet.
    function transferFrom(
        address token,
        address from,
        address to,
        uint256 amount,
        bytes calldata data,
        bool fromDeposit,
        bool toDeposit
    )
    external
    onlyAuthorized
    onlyUserApproved(from)
    nonReentrant
    {
        if (amount == 0 || from == to) {
            return;
        }
        uint256 tokenId = data.readUint256(0);
        if (fromDeposit) {
            require(hasDeposit(token, from, tokenId, data));
            removeToken(token, from, tokenId);
            if (toDeposit) {
                // Deposit to deposit
                deposits[token][to].push(tokenId);
            } else {
                // Deposit to wallet
                transferFallback(token, to, tokenId);
            }
        } else {
            if (toDeposit) {
                // Wallet to deposit
                IERC721(token).transferFrom(from, address(this), tokenId);
                deposits[token][to].push(tokenId);
            } else {
                // Wallet to wallet
                IERC721(token).transferFrom(from, to, tokenId);
            }
        }
    }

    /// Some older tokens only implement transfer(...) instead of transferFrom(...) which required by ERC721 standard.
    /// First, the function tries to call transferFrom(...) using raw assembly call to avoid EVM reverts.
    /// If failed, call transfer(...) as a fallback.
    /// @param token Token address.
    /// @param to The new token owner address.
    /// @param tokenId Token ID.
    function transferFallback(address token, address to, uint256 tokenId) internal {
        bytes memory callData = abi.encodeWithSelector(
            IERC721(token).transferFrom.selector,
            address(this),
            to,
            tokenId
        );
        bool result;
        assembly {
            let cdStart := add(callData, 32)
            result := call(
                gas,                // forward all gas
                token,              // address of token contract
                0,                  // don't send any ETH
                cdStart,            // pointer to start of input
                mload(callData),    // length of input
                cdStart,            // write output over input
                0                   // output size is 0
            )
        }
        if (!result) {
            IERC721(token).transfer(to, tokenId);
            emit TransferFallback(token);
        }
    }

    /// Remove token from deposit.
    /// @param token Token address.
    /// @param user User address.
    /// @param tokenId Token ID.
    function removeToken(address token, address user, uint256 tokenId) internal {
        for (uint256 i = 0; i < deposits[token][user].length; i++) {
            if (tokenId == deposits[token][user][i]) {
                deposits[token][user][i] = deposits[token][user][deposits[token][user].length - 1];
                delete deposits[token][user][deposits[token][user].length - 1];
                deposits[token][user].length--;
                return;
            }
        }
    }
}
