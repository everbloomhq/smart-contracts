pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {ERC20SafeTransfer} from "../lib/ERC20SafeTransfer.sol";
import {LibBytes} from "../lib/LibBytes.sol";
import {LibMath} from "../lib/LibMath.sol";
import {IExchangeHandler} from "./IExchangeHandler.sol";
import {RouterCommon} from "./RouterCommon.sol";

/// Interface of core EtherDelta contract.
interface IEtherDelta {
    function feeTake() external view returns (uint256);
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function depositToken(address token, uint256 amount) external;
    function withdrawToken(address token, uint256 amount) external;
    function trade(address tokenGet, uint256 amountGet, address tokenGive, uint256 amountGive, uint256 expires, uint256 nonce, address user, uint8 v, bytes32 r, bytes32 s, uint256 amount) external;
    function availableVolume(address tokenGet, uint256 amountGet, address tokenGive, uint256 amountGive, uint256 expires, uint256 nonce, address user, uint8 v, bytes32 r, bytes32 s) external view returns (uint256);
}

// Interface of ERC20 approve function.
interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
}

/// EtherDelta implementation of exchange handler.
contract EtherDeltaHandler is IExchangeHandler, LibMath {

    using LibBytes for bytes;

    IEtherDelta public EXCHANGE;
    address public ROUTER;
    address payable public FEE_ACCOUNT;
    uint256 public PROCESSING_FEE_PERCENTAGE;

    struct EdOrder {
        address tokenGet;
        uint256 amountGet;
        address tokenGive;
        uint256 amountGive;
        uint256 expires;
        uint256 nonce;
        address user;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    constructor(
        address exchange,
        address router,
        address payable feeAccount,
        uint256 processingFeePercentage
    )
    public
    {
        EXCHANGE = IEtherDelta(exchange);
        ROUTER = router;
        FEE_ACCOUNT = feeAccount;
        PROCESSING_FEE_PERCENTAGE = processingFeePercentage;
    }

    /// Fallback function to receive ETH.
    function() external payable {}

    /// Gets maximum available amount can be spent on order (order fee included).
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
        EdOrder memory edOrder = getOrder(data);
        availableToFill = EXCHANGE.availableVolume(
            edOrder.tokenGet,
            edOrder.amountGet,
            edOrder.tokenGive,
            edOrder.amountGive,
            edOrder.expires,
            edOrder.nonce,
            edOrder.user,
            edOrder.v,
            edOrder.r,
            edOrder.s
        );
        feePercentage = add(EXCHANGE.feeTake(), PROCESSING_FEE_PERCENTAGE);
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
        EdOrder memory edOrder = getOrder(data);
        uint256 exchangeFeePercentage = EXCHANGE.feeTake();
        uint256 exchangeFee = mul(takerAmountToFill, exchangeFeePercentage) / (1 ether);
        uint256 processingFee = sub(
            mul(takerAmountToFill, add(exchangeFeePercentage, PROCESSING_FEE_PERCENTAGE)) / (1 ether),
            exchangeFee
        );
        uint256 depositAmount = add(takerAmountToFill, exchangeFee);
        makerAmountReceived = getPartialAmountFloor(edOrder.amountGive, edOrder.amountGet, takerAmountToFill);

        // Makes deposit on exchange and pays processing fee using taker token in this contract.
        if (edOrder.tokenGet == address(0)) {
            EXCHANGE.deposit.value(depositAmount)();
            if (processingFee > 0) {
                require(FEE_ACCOUNT.send(processingFee), "FAILED_SEND_ETH_TO_FEE_ACCOUNT");
            }
        } else {
            require(IERC20(edOrder.tokenGet).approve(address(EXCHANGE), depositAmount));
            EXCHANGE.depositToken(edOrder.tokenGet, depositAmount);
            if (processingFee > 0) {
                require(ERC20SafeTransfer.safeTransfer(edOrder.tokenGet, FEE_ACCOUNT, processingFee), "FAILED_SEND_ERC20_TO_FEE_ACCOUNT");
            }
        }

        // Trades on exchange.
        trade(edOrder, takerAmountToFill);

        // Withdraws maker tokens to this contract, then sends back to router.
        if (edOrder.tokenGive == address(0)) {
            EXCHANGE.withdraw(makerAmountReceived);
            require(msg.sender.send(makerAmountReceived), "FAILED_SEND_ETH_TO_ROUTER");
        } else {
            EXCHANGE.withdrawToken(edOrder.tokenGive, makerAmountReceived);
            require(ERC20SafeTransfer.safeTransfer(edOrder.tokenGive, msg.sender, makerAmountReceived), "FAILED_SEND_ERC20_TO_ROUTER");
        }
    }

    /// Trade on EtherDelta exchange.
    /// @param edOrder Order object in EtherDelta format.
    function trade(
        EdOrder memory edOrder,
        uint256 takerAmountToFill
    )
    internal
    {
        EXCHANGE.trade(
            edOrder.tokenGet,
            edOrder.amountGet,
            edOrder.tokenGive,
            edOrder.amountGive,
            edOrder.expires,
            edOrder.nonce,
            edOrder.user,
            edOrder.v,
            edOrder.r,
            edOrder.s,
            takerAmountToFill
        );
    }

    /// Assembles order object in EtherDelta format.
    /// @param data General order data.
    /// @return edOrder Order object in EtherDelta format.
    function getOrder(
        bytes memory data
    )
    internal
    pure
    returns (EdOrder memory edOrder)
    {
        edOrder.tokenGet = data.readAddress(12);
        edOrder.amountGet = data.readUint256(32);
        edOrder.tokenGive = data.readAddress(76);
        edOrder.amountGive = data.readUint256(96);
        edOrder.expires = data.readUint256(128);
        edOrder.nonce = data.readUint256(160);
        edOrder.user = data.readAddress(204);
        edOrder.v = uint8(data.readUint256(224));
        edOrder.r = data.readBytes32(256);
        edOrder.s = data.readBytes32(288);
    }
}
