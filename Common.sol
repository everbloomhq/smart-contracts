pragma solidity ^0.5.7;

contract Common {
    struct Order {
        address maker;
        address taker;
        address makerToken;
        address takerToken;
        address makerTokenBank;
        address takerTokenBank;
        address reseller;
        address verifier;
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 expires;
        uint256 nonce;
        uint256 minimumTakerAmount;
        bytes makerData;
        bytes takerData;
        bytes signature;
    }

    struct OrderInfo {
        uint8 orderStatus;
        bytes32 orderHash;
        uint256 filledTakerAmount;
    }

    struct FillResults {
        uint256 makerFilledAmount;
        uint256 makerFeeExchange;
        uint256 makerFeeReseller;
        uint256 takerFilledAmount;
        uint256 takerFeeExchange;
        uint256 takerFeeReseller;
    }

    struct MatchedFillResults {
        FillResults left;
        FillResults right;
        uint256 spreadAmount;
    }
}