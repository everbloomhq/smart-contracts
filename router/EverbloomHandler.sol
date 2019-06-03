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
        Common.Order memory order = getOrder(data);
        Common.OrderInfo memory orderInfo = EXCHANGE.getOrderInfo(order);
        if ((order.taker != address(0) && order.taker != address(this)) ||
            order.minimumTakerAmount > 0 ||
            order.minimumTakerAmount > 0 ||
            orderInfo.orderStatus != 4
        ) {
            availableToFill = 0;
        } else {
            availableToFill = sub(order.takerAmount, orderInfo.filledTakerAmount);
        }
        feePercentage = EXCHANGE.fees(order.reseller, 2);
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
        Common.Order memory order = getOrder(data);
        uint256 depositAmount = add(takerAmountToFill, mul(takerAmountToFill, EXCHANGE.fees(order.reseller, 2)) / (1 ether));
        // Makes deposit on exchange using taker token in this contract.
        if (order.takerToken == address(0)) {
            IBank(order.takerTokenBank).deposit.value(depositAmount)(address(0), address(this), depositAmount, "");
        } else {
            IERC20(order.takerToken).approve(order.takerTokenBank, depositAmount);
            IBank(order.takerTokenBank).deposit(order.takerToken, address(this), depositAmount, "");
        }
        // Approves exchange to access bank.
        IBank(order.takerTokenBank).userApprove(address(EXCHANGE), true);

        // Trades on exchange.
        Common.FillResults memory results = EXCHANGE.fillOrder(
            order,
            takerAmountToFill,
            false
        );
        // Withdraws maker tokens to this contract, then sends back to router.
        if (results.makerFilledAmount > 0) {
            IBank(order.makerTokenBank).withdraw(order.makerToken, results.makerFilledAmount, "");
            if (order.makerToken == address(0)) {
                require(msg.sender.send(results.makerFilledAmount), "FAILED_SEND_ETH_TO_ROUTER");
            } else {
                require(ERC20SafeTransfer.safeTransfer(order.makerToken, msg.sender, results.makerFilledAmount), "FAILED_SEND_ERC20_TO_ROUTER");
            }
        }
        makerAmountReceived = results.makerFilledAmount;
    }

    /// Assembles order object in Everbloom format.
    /// @param data General order data.
    /// @return order Order object in Everbloom format.
    function getOrder(
        bytes memory data
    )
    internal
    pure
    returns (Common.Order memory order)
    {
        uint256 makerDataOffset = data.readUint256(416);
        uint256 takerDataOffset = data.readUint256(448);
        uint256 signatureOffset = data.readUint256(480);
        order.maker = data.readAddress(12);
        order.taker = data.readAddress(44);
        order.makerToken = data.readAddress(76);
        order.takerToken = data.readAddress(108);
        order.makerTokenBank = data.readAddress(140);
        order.takerTokenBank = data.readAddress(172);
        order.reseller = data.readAddress(204);
        order.verifier = data.readAddress(236);
        order.makerAmount = data.readUint256(256);
        order.takerAmount = data.readUint256(288);
        order.expires = data.readUint256(320);
        order.nonce = data.readUint256(352);
        order.minimumTakerAmount = data.readUint256(384);
        order.makerData = data.slice(makerDataOffset + 32, makerDataOffset + 32 + data.readUint256(makerDataOffset));
        order.takerData = data.slice(takerDataOffset + 32, takerDataOffset + 32 + data.readUint256(takerDataOffset));
        order.signature = data.slice(signatureOffset + 32, signatureOffset + 32 + data.readUint256(signatureOffset));
    }
}
