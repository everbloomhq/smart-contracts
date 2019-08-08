pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {ERC20SafeTransfer} from "../lib/ERC20SafeTransfer.sol";
import {LibBytes} from "../lib/LibBytes.sol";
import {LibMath} from "../lib/LibMath.sol";
import {Ownable} from "../lib/Ownable.sol";
import {IExchangeHandler} from "./IExchangeHandler.sol";
import {RouterCommon} from "./RouterCommon.sol";

/// Abstract contract of core 0x v2 contract.
contract ZeroExV2Exchange {
    struct Order {
        address makerAddress;           // Address that created the order.
        address takerAddress;           // Address that is allowed to fill the order. If set to 0, any address is allowed to fill the order.
        address feeRecipientAddress;    // Address that will recieve fees when order is filled.
        address senderAddress;          // Address that is allowed to call Exchange contract methods that affect this order. If set to 0, any address is allowed to call these methods.
        uint256 makerAssetAmount;       // Amount of makerAsset being offered by maker. Must be greater than 0.
        uint256 takerAssetAmount;       // Amount of takerAsset being bid on by maker. Must be greater than 0.
        uint256 makerFee;               // Amount of ZRX paid to feeRecipient by maker when order is filled. If set to 0, no transfer of ZRX from maker to feeRecipient will be attempted.
        uint256 takerFee;               // Amount of ZRX paid to feeRecipient by taker when order is filled. If set to 0, no transfer of ZRX from taker to feeRecipient will be attempted.
        uint256 expirationTimeSeconds;  // Timestamp in seconds at which order expires.
        uint256 salt;                   // Arbitrary number to facilitate uniqueness of the order's hash.
        bytes makerAssetData;           // Encoded data that can be decoded by a specified proxy contract when transferring makerAsset. The last byte references the id of this proxy.
        bytes takerAssetData;           // Encoded data that can be decoded by a specified proxy contract when transferring takerAsset. The last byte references the id of this proxy.
    }

    struct OrderInfo {
        uint8 orderStatus;                    // Status that describes order's validity and fillability.
        bytes32 orderHash;                    // EIP712 hash of the order (see LibOrder.getOrderHash).
        uint256 orderTakerAssetFilledAmount;  // Amount of order that has already been filled.
    }

    struct FillResults {
        uint256 makerAssetFilledAmount;  // Total amount of makerAsset(s) filled.
        uint256 takerAssetFilledAmount;  // Total amount of takerAsset(s) filled.
        uint256 makerFeePaid;            // Total amount of ZRX paid by maker(s) to feeRecipient(s).
        uint256 takerFeePaid;            // Total amount of ZRX paid by taker to feeRecipients(s).
    }

    function getAssetProxy(bytes4 assetProxyId)
    external
    view
    returns (address);

    function isValidSignature(
        bytes32 hash,
        address signerAddress,
        bytes calldata signature
    )
    external
    view
    returns (bool isValid);

    function fillOrder(
        Order calldata order,
        uint256 takerAssetFillAmount,
        bytes calldata signature
    )
    external
    returns (FillResults memory fillResults);

    function getOrderInfo(Order calldata order)
    external
    view
    returns (OrderInfo memory orderInfo);
}

/// Interface of ERC20 approve function.
interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
}

// Simple WETH interface to wrap ETH.
interface IWETH {
    function deposit() external payable;
}

/// 0x v2 implementation of exchange handler. ERC721 orders are not currently supported.
contract ZeroExV2Handler is IExchangeHandler, LibMath, Ownable {

    using LibBytes for bytes;

    ZeroExV2Exchange constant public EXCHANGE = ZeroExV2Exchange(0x080bf510FCbF18b91105470639e9561022937712);
    address constant public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public ROUTER;
    address payable public FEE_ACCOUNT;
    uint256 public PROCESSING_FEE_PERCENTAGE;

    constructor(
        address router,
        address payable feeAccount,
        uint256 processingFeePercentage
    ) public {
        ROUTER = router;
        FEE_ACCOUNT = feeAccount;
        PROCESSING_FEE_PERCENTAGE = processingFeePercentage;
    }

    /// Fallback function to receive ETH.
    function() external payable {}

    /// Sets fee account. Only contract owner can call this function.
    /// @param feeAccount Fee account address.
    function setFeeAccount(
        address payable feeAccount
    )
    external
    onlyOwner
    {
        FEE_ACCOUNT = feeAccount;
    }

    /// Gets maximum available amount can be spent on order (fee not included).
    /// @param data General order data.
    /// @return availableToFill Amount can be spent on order.
    /// @return feePercentage Fee percentage of order.
    function getAvailableToFill(
        bytes calldata data
    )
    external
    view
    returns (uint256 availableToFill, uint256 feePercentage)
    {
        (ZeroExV2Exchange.Order memory order, bytes memory signature) = getOrder(data);
        ZeroExV2Exchange.OrderInfo memory orderInfo = EXCHANGE.getOrderInfo(order);
        if ((order.takerAddress == address(0) || order.takerAddress == address(this)) &&
            (order.senderAddress == address(0) || order.senderAddress == address(this)) &&
            order.takerFee == 0 &&
            orderInfo.orderStatus == 3 &&
            EXCHANGE.isValidSignature(orderInfo.orderHash, order.makerAddress, signature)
        ) {
            availableToFill = sub(order.takerAssetAmount, orderInfo.orderTakerAssetFilledAmount);
        }
        feePercentage = PROCESSING_FEE_PERCENTAGE;
    }

    /// Fills an order on the target exchange.
    /// NOTE: The required funds must be transferred to this contract in the same transaction of calling this function.
    /// @param data General order data.
    /// @param takerAmountToFill Taker token amount to spend on order (fee not included).
    /// @return makerAmountReceived Amount received from trade.
    function fillOrder(
        bytes calldata data,
        uint256 takerAmountToFill
    )
    external
    payable
    returns (uint256 makerAmountReceived)
    {
        require(msg.sender == ROUTER, "SENDER_NOT_ROUTER");
        (ZeroExV2Exchange.Order memory order, bytes memory signature) = getOrder(data);
        address makerToken = order.makerAssetData.readAddress(16);
        address takerToken = order.takerAssetData.readAddress(16);
        uint256 processingFee = mul(takerAmountToFill, PROCESSING_FEE_PERCENTAGE) / (1 ether);
        if (takerToken == WETH) {
            IWETH(WETH).deposit.value(takerAmountToFill)();
            if (processingFee > 0) {
                require(FEE_ACCOUNT.send(processingFee), "FAILED_SEND_ETH_TO_FEE_ACCOUNT");
            }
        } else if (processingFee > 0) {
            require(ERC20SafeTransfer.safeTransfer(takerToken, FEE_ACCOUNT, processingFee), "FAILED_SEND_ERC20_TO_FEE_ACCOUNT");
        }
        require(IERC20(takerToken).approve(EXCHANGE.getAssetProxy(order.takerAssetData.readBytes4(0)), takerAmountToFill));
        ZeroExV2Exchange.FillResults memory results = EXCHANGE.fillOrder(
            order,
            takerAmountToFill,
            signature
        );
        makerAmountReceived = results.makerAssetFilledAmount;
        if (makerAmountReceived > 0) {
            require(ERC20SafeTransfer.safeTransfer(makerToken, msg.sender, makerAmountReceived), "FAILED_SEND_ERC20_TO_ROUTER");
        }
    }

    /// Assembles order object in 0x format.
    /// @param data General order data.
    /// @return order Order object in 0x format.
    /// @return signature Signature object in 0x format.
    function getOrder(
        bytes memory data
    )
    internal
    pure
    returns (ZeroExV2Exchange.Order memory order, bytes memory signature)
    {
        uint256 makerAssetDataOffset = data.readUint256(320);
        uint256 takerAssetDataOffset = data.readUint256(352);
        uint256 signatureOffset = data.readUint256(384);
        order.makerAddress = data.readAddress(12);
        order.takerAddress = data.readAddress(44);
        order.feeRecipientAddress = data.readAddress(76);
        order.senderAddress = data.readAddress(108);
        order.makerAssetAmount = data.readUint256(128);
        order.takerAssetAmount = data.readUint256(160);
        order.makerFee = data.readUint256(192);
        order.takerFee = data.readUint256(224);
        order.expirationTimeSeconds = data.readUint256(256);
        order.salt = data.readUint256(288);
        order.makerAssetData = data.slice(makerAssetDataOffset + 32, makerAssetDataOffset + 32 + data.readUint256(makerAssetDataOffset));
        order.takerAssetData = data.slice(takerAssetDataOffset + 32, takerAssetDataOffset + 32 + data.readUint256(takerAssetDataOffset));
        signature = data.slice(signatureOffset + 32, signatureOffset + 32 + data.readUint256(signatureOffset));
    }

}
