pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {ERC20SafeTransfer} from "../lib/ERC20SafeTransfer.sol";
import {LibBytes} from "../lib/LibBytes.sol";
import {LibMath} from "../lib/LibMath.sol";
import {Ownable} from "../lib/Ownable.sol";
import {IExchangeHandler} from "./IExchangeHandler.sol";
import {RouterCommon} from "./RouterCommon.sol";

/// Interface of core uniswap exchange contract.
interface IUniswapExchange {
    function ethToTokenTransferInput(uint256 min_tokens, uint256 deadline, address recipient) external payable returns (uint256  tokens_bought);
    function tokenToEthTransferInput(uint256 tokens_sold, uint256 min_tokens, uint256 deadline, address recipient) external returns (uint256  eth_bought);
    function tokenToTokenTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address token_addr) external returns (uint256  tokens_bought);
}

/// Interface of core uniswap factory contract.
interface IUniswapFactory {
    function getExchange(address token) external view returns (address exchange);
}

/// Interface of ERC20 approve function.
interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// Uniswap implementation of exchange handler. ERC721 orders are not currently supported.
contract UniswapHandler is IExchangeHandler, LibMath, Ownable {

    using LibBytes for bytes;

    IUniswapFactory constant public FACTORY = IUniswapFactory(0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95);
    address public ROUTER;
    address payable public FEE_ACCOUNT;
    uint256 public PROCESSING_FEE_PERCENTAGE;

    struct Order {
        address makerToken;
        address takerToken;
        uint256 makerAmount;
        uint256 takerAmount;
    }

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
        Order memory order = getOrder(data);
        if (getMakerAmount(order) >= order.makerAmount) {
            availableToFill = order.takerAmount;
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
        Order memory order = getOrder(data);
        uint256 processingFee = mul(takerAmountToFill, PROCESSING_FEE_PERCENTAGE) / (1 ether);
        if (order.takerToken == address(0)) {
            // Use ETH to by token
            IUniswapExchange exchange = IUniswapExchange(FACTORY.getExchange(order.makerToken));
            makerAmountReceived = exchange.ethToTokenTransferInput.value(takerAmountToFill)(
                order.makerAmount,
                block.timestamp,
                msg.sender
            );
            if (processingFee > 0) {
                require(FEE_ACCOUNT.send(processingFee), "FAILED_SEND_ETH_TO_FEE_ACCOUNT");
            }
        } else {
            address exchangeAddr = FACTORY.getExchange(order.takerToken);
            IUniswapExchange exchange = IUniswapExchange(exchangeAddr);
            require(IERC20(order.takerToken).approve(exchangeAddr, takerAmountToFill));
            if (order.makerToken == address(0)) {
                // Use token to buy ETH
                makerAmountReceived = exchange.tokenToEthTransferInput(
                    takerAmountToFill,
                    order.makerAmount,
                    block.timestamp,
                    msg.sender
                );
            } else {
                // Use token to buy another token
                makerAmountReceived = exchange.tokenToTokenTransferInput(
                    takerAmountToFill,
                    order.makerAmount,
                    1,
                    block.timestamp,
                    msg.sender,
                    order.makerToken
                );
            }
            if (processingFee > 0) {
                require(ERC20SafeTransfer.safeTransfer(order.takerToken, FEE_ACCOUNT, processingFee), "FAILED_SEND_ERC20_TO_FEE_ACCOUNT");
            }
        }
    }

    function getMakerAmount(
        Order memory order
    )
    internal
    view
    returns (uint256 makerAmount)
    {
        if (order.makerToken == address(0) && order.takerToken != address(0)) {
            address exchangeAddr = FACTORY.getExchange(order.takerToken);
            makerAmount = getOutputAmount(
                order.takerAmount,
                IERC20(order.takerToken).balanceOf(exchangeAddr),
                exchangeAddr.balance
            );
            return makerAmount;
        }
        if (order.makerToken != address(0) && order.takerToken == address(0)) {
            address exchangeAddr = FACTORY.getExchange(order.makerToken);
            makerAmount = getOutputAmount(
                order.takerAmount,
                exchangeAddr.balance,
                IERC20(order.makerToken).balanceOf(exchangeAddr)
            );
            return makerAmount;
        }
        if (order.makerToken != address(0) && order.takerToken != address(0)) {
            address makerExchangeAddr = FACTORY.getExchange(order.makerToken);
            address takerExchangeAddr = FACTORY.getExchange(order.takerToken);
            uint256 ethAmount = getOutputAmount(
                order.takerAmount,
                IERC20(order.takerToken).balanceOf(takerExchangeAddr),
                takerExchangeAddr.balance
            );
            makerAmount = getOutputAmount(
                ethAmount,
                makerExchangeAddr.balance,
                IERC20(order.makerToken).balanceOf(makerExchangeAddr)
            );
            return makerAmount;
        }
    }

    function getOutputAmount(
        uint256 inputAmount,
        uint256 inputReserve,
        uint256 outputReserve
    )
    internal
    pure
    returns (uint256) {
        if (inputReserve == 0 || outputReserve == 0) {
            return 0;
        }
        uint256 inputAmountWithFee = mul(inputAmount, 997);
        uint256 numerator = mul(inputAmountWithFee, outputReserve);
        uint256 denominator = add(mul(inputReserve, 1000), inputAmountWithFee);
        return div(numerator, denominator);
    }

    /// Assembles order object in Uniswap format.
    /// @param data General order data.
    /// @return order Order object in Uniswap format.
    function getOrder(
        bytes memory data
    )
    internal
    pure
    returns (Order memory order)
    {
        order.makerToken = data.readAddress(12);
        order.takerToken = data.readAddress(44);
        order.makerAmount = data.readUint256(64);
        order.takerAmount = data.readUint256(96);
    }

}
