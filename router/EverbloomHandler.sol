pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {ERC20SafeTransfer} from "../lib/ERC20SafeTransfer.sol";
import {LibBytes} from "../lib/LibBytes.sol";
import {LibMath} from "../lib/LibMath.sol";
import {IBank} from "../bank/IBank.sol";
import {IExchangeHandler} from "./IExchangeHandler.sol";
import {Common} from "../Common.sol";
import {RouterCommon} from "./RouterCommon.sol";

/// Interface of core Everbloom exchange contract.
interface IEB {
    function fees(
        address reseller,
        uint256 feeType
    )
    external
    view
    returns (uint256);

    function fillOrder(
        Common.Order calldata order,
        uint256 takerAmountToFill,
        bool allowInsufficient
    )
    external
    returns (Common.FillResults memory results);

    function getOrderInfo(
        Common.Order calldata order
    )
    external
    view
    returns (Common.OrderInfo memory orderInfo);
}

/// Interface of ERC20 approve function.
interface IERC20 {
    function approve(
        address spender,
        uint256 value
    ) external;
}

/// Everbloom exchange implementation of exchange handler. ERC721 orders, KYCed orders are not currently supported.
contract EverbloomHandler is IExchangeHandler, LibMath {

    using LibBytes for bytes;

    IEB public EXCHANGE;
    address public ROUTER;

    constructor(
        address exchange,
        address router
    )
    public
    {
        EXCHANGE = IEB(exchange);
        ROUTER = router;
    }

    /// Fallback function to receive ETH.
    function() external payable {}

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
        Common.Order memory ebOrder = getOrder(data);
        Common.OrderInfo memory orderInfo = EXCHANGE.getOrderInfo(ebOrder);
        if ((ebOrder.taker != address(0) && ebOrder.taker != address(this)) ||
            ebOrder.minimumTakerAmount > 0 ||
            ebOrder.minimumTakerAmount > 0 ||
            orderInfo.orderStatus != 4
        ) {
            availableToFill = 0;
        } else {
            availableToFill = sub(ebOrder.takerAmount, orderInfo.filledTakerAmount);
        }
        feePercentage = EXCHANGE.fees(ebOrder.reseller, 2);
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
        Common.Order memory ebOrder = getOrder(data);
        uint256 depositAmount = add(takerAmountToFill, mul(takerAmountToFill, EXCHANGE.fees(ebOrder.reseller, 2)) / (1 ether));
        // Makes deposit on exchange using taker token in this contract.
        if (ebOrder.takerToken == address(0)) {
            IBank(ebOrder.takerTokenBank).deposit.value(depositAmount)(address(0), address(this), depositAmount, "");
        } else {
            IERC20(ebOrder.takerToken).approve(ebOrder.takerTokenBank, depositAmount);
            IBank(ebOrder.takerTokenBank).deposit(ebOrder.takerToken, address(this), depositAmount, "");
        }
        // Approves exchange to access bank.
        IBank(ebOrder.takerTokenBank).userApprove(address(EXCHANGE), true);

        // Trades on exchange.
        Common.FillResults memory results = EXCHANGE.fillOrder(
            ebOrder,
            takerAmountToFill,
            false
        );
        // Withdraws maker tokens to this contract, then sends back to router.
        if (results.makerFilledAmount > 0) {
            IBank(ebOrder.makerTokenBank).withdraw(ebOrder.makerToken, results.makerFilledAmount, "");
            if (ebOrder.makerToken == address(0)) {
                require(msg.sender.send(results.makerFilledAmount), "FAILED_SEND_ETH_TO_ROUTER");
            } else {
                require(ERC20SafeTransfer.safeTransfer(ebOrder.makerToken, msg.sender, results.makerFilledAmount), "FAILED_SEND_ERC20_TO_ROUTER");
            }
        }
        makerAmountReceived = results.makerFilledAmount;
    }

    /// Assembles order object in EtherDelta format.
    /// @param data General order data.
    /// @return order Order object in EtherDelta format.
    function getOrder(
        bytes memory data
    )
    internal
    pure
    returns (Common.Order memory ebOrder)
    {
        uint256 makerDataOffset = data.readUint256(416);
        uint256 takerDataOffset = data.readUint256(448);
        uint256 signatureOffset = data.readUint256(480);
        ebOrder.maker = data.readAddress(12);
        ebOrder.taker = data.readAddress(44);
        ebOrder.makerToken = data.readAddress(76);
        ebOrder.takerToken = data.readAddress(108);
        ebOrder.makerTokenBank = data.readAddress(140);
        ebOrder.takerTokenBank = data.readAddress(172);
        ebOrder.reseller = data.readAddress(204);
        ebOrder.verifier = data.readAddress(236);
        ebOrder.makerAmount = data.readUint256(256);
        ebOrder.takerAmount = data.readUint256(288);
        ebOrder.expires = data.readUint256(320);
        ebOrder.nonce = data.readUint256(352);
        ebOrder.minimumTakerAmount = data.readUint256(384);
        ebOrder.makerData = data.slice(makerDataOffset + 32, makerDataOffset + 32 + data.readUint256(makerDataOffset));
        ebOrder.takerData = data.slice(takerDataOffset + 32, takerDataOffset + 32 + data.readUint256(takerDataOffset));
        ebOrder.signature = data.slice(signatureOffset + 32, signatureOffset + 32 + data.readUint256(signatureOffset));
    }
}
