pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {ERC20SafeTransfer} from "../lib/ERC20SafeTransfer.sol";
import {LibBytes} from "../lib/LibBytes.sol";
import {LibMath} from "../lib/LibMath.sol";
import {Ownable} from "../lib/Ownable.sol";
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
contract EtherDeltaHandler is IExchangeHandler, LibMath, Ownable {

    using LibBytes for bytes;

    IEtherDelta constant public EXCHANGE = IEtherDelta(0x8d12A197cB00D4747a1fe03395095ce2A5CC6819);
    address public ROUTER;
    address payable public FEE_ACCOUNT;
    uint256 public PROCESSING_FEE_PERCENTAGE;

    struct Order {
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
        address router,
        address payable feeAccount,
        uint256 processingFeePercentage
    )
    public
    {
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
        Order memory order = getOrder(data);
        availableToFill = EXCHANGE.availableVolume(
            order.tokenGet,
            order.amountGet,
            order.tokenGive,
            order.amountGive,
            order.expires,
            order.nonce,
            order.user,
            order.v,
            order.r,
            order.s
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
        Order memory order = getOrder(data);
        uint256 exchangeFeePercentage = EXCHANGE.feeTake();
        uint256 exchangeFee = mul(takerAmountToFill, exchangeFeePercentage) / (1 ether);
        uint256 processingFee = sub(
            mul(takerAmountToFill, add(exchangeFeePercentage, PROCESSING_FEE_PERCENTAGE)) / (1 ether),
            exchangeFee
        );
        uint256 depositAmount = add(takerAmountToFill, exchangeFee);
        makerAmountReceived = getPartialAmountFloor(order.amountGive, order.amountGet, takerAmountToFill);

        // Makes deposit on exchange and pays processing fee using taker token in this contract.
        if (order.tokenGet == address(0)) {
            EXCHANGE.deposit.value(depositAmount)();
            if (processingFee > 0) {
                require(FEE_ACCOUNT.send(processingFee), "FAILED_SEND_ETH_TO_FEE_ACCOUNT");
            }
        } else {
            require(IERC20(order.tokenGet).approve(address(EXCHANGE), depositAmount));
            EXCHANGE.depositToken(order.tokenGet, depositAmount);
            if (processingFee > 0) {
                require(ERC20SafeTransfer.safeTransfer(order.tokenGet, FEE_ACCOUNT, processingFee), "FAILED_SEND_ERC20_TO_FEE_ACCOUNT");
            }
        }

        // Trades on exchange.
        trade(order, takerAmountToFill);

        // Withdraws maker tokens to this contract, then sends back to router.
        if (order.tokenGive == address(0)) {
            EXCHANGE.withdraw(makerAmountReceived);
            require(msg.sender.send(makerAmountReceived), "FAILED_SEND_ETH_TO_ROUTER");
        } else {
            EXCHANGE.withdrawToken(order.tokenGive, makerAmountReceived);
            require(ERC20SafeTransfer.safeTransfer(order.tokenGive, msg.sender, makerAmountReceived), "FAILED_SEND_ERC20_TO_ROUTER");
        }
    }

    /// Trade on EtherDelta exchange.
    /// @param order Order object in EtherDelta format.
    function trade(
        Order memory order,
        uint256 takerAmountToFill
    )
    internal
    {
        EXCHANGE.trade(
            order.tokenGet,
            order.amountGet,
            order.tokenGive,
            order.amountGive,
            order.expires,
            order.nonce,
            order.user,
            order.v,
            order.r,
            order.s,
            takerAmountToFill
        );
    }

    /// Assembles order object in EtherDelta format.
    /// @param data General order data.
    /// @return order Order object in EtherDelta format.
    function getOrder(
        bytes memory data
    )
    internal
    pure
    returns (Order memory order)
    {
        order.tokenGet = data.readAddress(12);
        order.amountGet = data.readUint256(32);
        order.tokenGive = data.readAddress(76);
        order.amountGive = data.readUint256(96);
        order.expires = data.readUint256(128);
        order.nonce = data.readUint256(160);
        order.user = data.readAddress(204);
        order.v = uint8(data.readUint256(224));
        order.r = data.readBytes32(256);
        order.s = data.readBytes32(288);
    }
}
