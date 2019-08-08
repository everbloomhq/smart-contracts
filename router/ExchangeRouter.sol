pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {LibMath} from "../lib/LibMath.sol";
import {Ownable} from "../lib/Ownable.sol";
import {ReentrancyGuard} from "../lib/ReentrancyGuard.sol";
import {IBank} from "../bank/IBank.sol";
import {IExchangeHandler} from "./IExchangeHandler.sol";
import {RouterCommon} from "./RouterCommon.sol";

// Interface of ERC20 approve function.
interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
}

/// Router contract to support orders from different decentralized exchanges.
contract ExchangeRouter is Ownable, ReentrancyGuard, LibMath {

    IBank public bank;
    mapping(address => bool) public handlerWhitelist;

    event Handler(address handler, bool allowed);
    event FillOrder(
        bytes orderData,
        uint256 makerAmountReceived,
        uint256 takerAmountSpentOnOrder,
        uint256 takerAmountSpentOnFee
    );

    constructor(
        address _bank
    )
    public
    {
        bank = IBank(_bank);
    }

    /// Fallback function to receive ETH.
    function() external payable {}

    /// Sets a handler. Only contract owner can call this function.
    /// @param handler Handler address.
    /// @param allowed allowed Whether the handler address is trusted.
    function setHandler(
        address handler,
        bool allowed
    )
    external
    onlyOwner
    {
        handlerWhitelist[handler] = allowed;
        emit Handler(handler, allowed);
    }

    /// Fills an order.
    /// @param order General order object.
    /// @param takerAmountToFill Taker token amount to spend on order.
    /// @param allowInsufficient Whether insufficient order remaining is allowed to fill.
    /// @return results Amounts paid and received.
    function fillOrder(
        RouterCommon.GeneralOrder memory order,
        uint256 takerAmountToFill,
        bool allowInsufficient
    )
    public
    nonReentrant
    returns (RouterCommon.FillResults memory results)
    {
        results = fillOrderInternal(
            order,
            takerAmountToFill,
            allowInsufficient
        );
    }

    /// Fills multiple orders by batch.
    /// @param orderList Array of general order objects.
    /// @param takerAmountToFillList Array of taker token amounts to spend on order.
    /// @param allowInsufficientList Array of booleans that whether insufficient order remaining is allowed to fill.
    function fillOrders(
        RouterCommon.GeneralOrder[] memory orderList,
        uint256[] memory takerAmountToFillList,
        bool[] memory allowInsufficientList
    )
    public
    nonReentrant
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            fillOrderInternal(
                orderList[i],
                takerAmountToFillList[i],
                allowInsufficientList[i]
            );
        }
    }

    /// Given a list of orders, fill them in sequence until total taker amount is reached.
    /// NOTE: All orders should be in the same token pair.
    /// @param orderList Array of general order objects.
    /// @param totalTakerAmountToFill Stop filling when the total taker amount is reached.
    /// @return totalFillResults Total amounts paid and received.
    function marketTakerOrders(
        RouterCommon.GeneralOrder[] memory orderList,
        uint256 totalTakerAmountToFill
    )
    public
    returns (RouterCommon.FillResults memory totalFillResults)
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            RouterCommon.FillResults memory singleFillResults = fillOrderInternal(
                orderList[i],
                sub(totalTakerAmountToFill, totalFillResults.takerAmountSpentOnOrder),
                true
            );
            addFillResults(totalFillResults, singleFillResults);
            if (totalFillResults.takerAmountSpentOnOrder >= totalTakerAmountToFill) {
                break;
            }
        }
        return totalFillResults;
    }

    /// Given a list of orders, fill them in sequence until total maker amount is reached.
    /// NOTE: All orders should be in the same token pair.
    /// @param orderList Array of general order objects.
    /// @param totalMakerAmountToFill Stop filling when the total maker amount is reached.
    /// @return totalFillResults Total amounts paid and received.
    function marketMakerOrders(
        RouterCommon.GeneralOrder[] memory orderList,
        uint256 totalMakerAmountToFill
    )
    public
    returns (RouterCommon.FillResults memory totalFillResults)
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            RouterCommon.FillResults memory singleFillResults = fillOrderInternal(
                orderList[i],
                getPartialAmountFloor(
                    orderList[i].takerAmount,
                    orderList[i].makerAmount,
                    sub(totalMakerAmountToFill, totalFillResults.makerAmountReceived)
                ),
                true
            );
            addFillResults(totalFillResults, singleFillResults);
            if (totalFillResults.makerAmountReceived >= totalMakerAmountToFill) {
                break;
            }
        }
        return totalFillResults;
    }

    /// Fills an order.
    /// @param order General order object.
    /// @param takerAmountToFill Taker token amount to spend on order.
    /// @param allowInsufficient Whether insufficient order remaining is allowed to fill.
    /// @return results Amounts paid and received.
    function fillOrderInternal(
        RouterCommon.GeneralOrder memory order,
        uint256 takerAmountToFill,
        bool allowInsufficient
    )
    internal
    returns (RouterCommon.FillResults memory results)
    {
        // Check if the handler is trusted.
        require(handlerWhitelist[order.handler], "HANDLER_IN_WHITELIST_REQUIRED");
        // Check order's availability.
        (uint256 availableToFill, uint256 feePercentage) = IExchangeHandler(order.handler).getAvailableToFill(order.data);

        if (allowInsufficient) {
            results.takerAmountSpentOnOrder = min(takerAmountToFill, availableToFill);
        } else {
            require(takerAmountToFill <= availableToFill, "INSUFFICIENT_ORDER_REMAINING");
            results.takerAmountSpentOnOrder = takerAmountToFill;
        }
        results.takerAmountSpentOnFee = mul(results.takerAmountSpentOnOrder, feePercentage) / (1 ether);
        if (results.takerAmountSpentOnOrder > 0) {
            // Transfer funds from bank deposit to corresponding handler.
            bank.transferFrom(
                order.takerToken,
                msg.sender,
                order.handler,
                add(results.takerAmountSpentOnOrder, results.takerAmountSpentOnFee),
                "",
                true,
                false
            );
            // Fill the order via handler.
            results.makerAmountReceived = IExchangeHandler(order.handler).fillOrder(
                order.data,
                results.takerAmountSpentOnOrder
            );
            if (results.makerAmountReceived > 0) {
                if (order.makerToken == address(0)) {
                    bank.deposit.value(results.makerAmountReceived)(
                        address(0),
                        msg.sender,
                        results.makerAmountReceived,
                        ""
                    );
                } else {
                    require(IERC20(order.makerToken).approve(address(bank), results.makerAmountReceived));
                    bank.deposit(
                        order.makerToken,
                        msg.sender,
                        results.makerAmountReceived,
                        ""
                    );
                }
            }
            emit FillOrder(
                order.data,
                results.makerAmountReceived,
                results.takerAmountSpentOnOrder,
                results.takerAmountSpentOnFee
            );
        }
    }

    /// @dev Adds properties of a single FillResults to total FillResults.
    /// @param totalFillResults Fill results instance that will be added onto.
    /// @param singleFillResults Fill results instance that will be added to totalFillResults.
    function addFillResults(
        RouterCommon.FillResults memory totalFillResults,
        RouterCommon.FillResults memory singleFillResults
    )
    internal
    pure
    {
        totalFillResults.makerAmountReceived = add(totalFillResults.makerAmountReceived, singleFillResults.makerAmountReceived);
        totalFillResults.takerAmountSpentOnOrder = add(totalFillResults.takerAmountSpentOnOrder, singleFillResults.takerAmountSpentOnOrder);
        totalFillResults.takerAmountSpentOnFee = add(totalFillResults.takerAmountSpentOnFee, singleFillResults.takerAmountSpentOnFee);
    }
}
