pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import {LibBytes} from "./lib/LibBytes.sol";
import {LibMath} from "./lib/LibMath.sol";
import {Ownable} from "./lib/Ownable.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";
import {IBank} from "./bank/IBank.sol";
import {Verifier} from "./verifier/Verifier.sol";
import {Common} from "./Common.sol";

/// Everbloom core exchange contract.
contract EverbloomExchange is Ownable, ReentrancyGuard, LibMath {

    using LibBytes for bytes;

    // All fees cannot beyond this percentage.
    uint256 public constant MAX_FEE_PERCENTAGE = 0.005 * 10 ** 18; // 0.5%

    // Exchange fee account.
    address public feeAccount;

    // Exchange fee schedule.
    // fees[reseller][0] is maker fee charged by exchange.
    // fees[reseller][1] is maker fee charged by reseller.
    // fees[reseller][2] is taker fee charged by exchange.
    // fees[reseller][3] is taker fee charged by reseller.
    // fees[0][0] is default maker fee charged by exchange if no reseller.
    // fees[0][1] is always 0 if no reseller.
    // fees[0][2] is default taker fee charged by exchange if no reseller.
    // fees[0][3] is always 0 if no reseller.
    mapping(address => uint256[4]) public fees;

    // Mapping of order filled amounts.
    // filled[orderHash] = filledAmount
    mapping(bytes32 => uint256) filled;

    // Mapping of cancelled orders.
    // cancelled[orderHash] = isCancelled
    mapping(bytes32 => bool) cancelled;

    // Mapping of different types of whitelists.
    // whitelists[whitelistType][address] = isAllowed
    mapping(uint8 => mapping(address => bool)) whitelists;

    enum WhitelistType {
        BANK,
        FEE_EXEMPT_BANK, // No percentage fees for non-dividable tokens.
        RESELLER,
        VERIFIER
    }

    enum OrderStatus {
        INVALID,
        INVALID_SIGNATURE,
        INVALID_MAKER_AMOUNT,
        INVALID_TAKER_AMOUNT,
        FILLABLE,
        EXPIRED,
        FULLY_FILLED,
        CANCELLED
    }

    event SetFeeAccount(address feeAccount);
    event SetFee(address reseller, uint256 makerFee, uint256 takerFee);
    event SetWhitelist(uint8 wlType, address addr, bool allowed);
    event CancelOrder(
        bytes32 indexed orderHash,
        address indexed maker,
        address makerToken,
        address takerToken,
        address indexed reseller,
        uint256 makerAmount,
        uint256 takerAmount,
        bytes makerData,
        bytes takerData
    );
    event FillOrder(
        bytes32 indexed orderHash,
        address indexed maker,
        address taker,
        address makerToken,
        address takerToken,
        address indexed reseller,
        uint256 makerFilledAmount,
        uint256 makerFeeExchange,
        uint256 makerFeeReseller,
        uint256 takerFilledAmount,
        uint256 takerFeeExchange,
        uint256 takerFeeReseller,
        bytes makerData,
        bytes takerData
    );

    /// Sets fee account. Only contract owner can call this function.
    /// @param _feeAccount Fee account address.
    function setFeeAccount(
        address _feeAccount
    )
    public
    onlyOwner
    {
        feeAccount = _feeAccount;
        emit SetFeeAccount(_feeAccount);
    }

    /// Sets fee schedule. Only contract owner can call this function.
    /// Each fee is a fraction of 1 ETH in wei.
    /// @param reseller Reseller address.
    /// @param _fees Array of four fees: makerFeeExchange, makerFeeReseller, takerFeeExchange, takerFeeReseller.
    function setFee(
        address reseller,
        uint256[4] calldata _fees
    )
    external
    onlyOwner
    {
        if (reseller == address(0)) {
            // If reseller is not set, reseller fee should not be set.
            require(_fees[1] == 0 && _fees[3] == 0, "INVALID_NULL_RESELLER_FEE");
        }
        uint256 makerFee = add(_fees[0], _fees[1]);
        uint256 takerFee = add(_fees[2], _fees[3]);
        // Total fees of an order should not beyond MAX_FEE_PERCENTAGE.
        require(add(makerFee, takerFee) <= MAX_FEE_PERCENTAGE, "FEE_TOO_HIGH");
        fees[reseller] = _fees;
        emit SetFee(reseller, makerFee, takerFee);
    }

    /// Sets address whitelist. Only contract owner can call this function.
    /// @param wlType Whitelist type (defined in enum WhitelistType, e.g. BANK).
    /// @param addr An address (e.g. a trusted bank address).
    /// @param allowed Whether the address is trusted.
    function setWhitelist(
        WhitelistType wlType,
        address addr,
        bool allowed
    )
    external
    onlyOwner
    {
        whitelists[uint8(wlType)][addr] = allowed;
        emit SetWhitelist(uint8(wlType), addr, allowed);
    }

    /// Cancels an order. Only order maker can call this function.
    /// @param order Order object.
    function cancelOrder(
        Common.Order memory order
    )
    public
    nonReentrant
    {
        cancelOrderInternal(order);
    }

    /// Cancels multiple orders by batch. Only order maker can call this function.
    /// @param orderList Array of order objects.
    function cancelOrders(
        Common.Order[] memory orderList
    )
    public
    nonReentrant
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            cancelOrderInternal(orderList[i]);
        }
    }

    /// Fills an order.
    /// @param order Order object.
    /// @param takerAmountToFill Desired amount of takerToken to sell.
    /// @param allowInsufficient Whether insufficient order remaining is allowed to fill.
    /// @return results Amounts filled and fees paid by maker and taker.
    function fillOrder(
        Common.Order memory order,
        uint256 takerAmountToFill,
        bool allowInsufficient
    )
    public
    nonReentrant
    returns (Common.FillResults memory results)
    {
        results = fillOrderInternal(
            order,
            takerAmountToFill,
            allowInsufficient
        );
        return results;
    }

    /// Fills an order without throwing an exception.
    /// @param order Order object.
    /// @param takerAmountToFill Desired amount of takerToken to sell.
    /// @param allowInsufficient Whether insufficient order remaining is allowed to fill.
    /// @return results Amounts filled and fees paid by maker and taker.
    function fillOrderNoThrow(
        Common.Order memory order,
        uint256 takerAmountToFill,
        bool allowInsufficient
    )
    public
    returns (Common.FillResults memory results)
    {
        bytes memory callData = abi.encodeWithSelector(
            this.fillOrder.selector,
            order,
            takerAmountToFill,
            allowInsufficient
        );
        assembly {
            // Use raw assembly call to fill order and avoid EVM reverts.
            let success := delegatecall(
                gas,                // forward all gas.
                address,            // call address of this contract.
                add(callData, 32),  // pointer to start of input (skip array length in first 32 bytes).
                mload(callData),    // length of input.
                callData,           // write output over input.
                192                 // output size is 192 bytes.
            )
            // Copy output data.
            if success {
                mstore(results, mload(callData))
                mstore(add(results, 32), mload(add(callData, 32)))
                mstore(add(results, 64), mload(add(callData, 64)))
                mstore(add(results, 96), mload(add(callData, 96)))
                mstore(add(results, 128), mload(add(callData, 128)))
                mstore(add(results, 160), mload(add(callData, 160)))
            }
        }
        return results;
    }

    /// Fills multiple orders by batch.
    /// @param orderList Array of order objects.
    /// @param takerAmountToFillList Array of desired amounts of takerToken to sell.
    /// @param allowInsufficientList Array of booleans that whether insufficient order remaining is allowed to fill.
    function fillOrders(
        Common.Order[] memory orderList,
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

    /// Fills multiple orders by batch without throwing an exception.
    /// @param orderList Array of order objects.
    /// @param takerAmountToFillList Array of desired amounts of takerToken to sell.
    /// @param allowInsufficientList Array of booleans that whether insufficient order remaining is allowed to fill.
    function fillOrdersNoThrow(
        Common.Order[] memory orderList,
        uint256[] memory takerAmountToFillList,
        bool[] memory allowInsufficientList
    )
    public
    nonReentrant
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            fillOrderNoThrow(
                orderList[i],
                takerAmountToFillList[i],
                allowInsufficientList[i]
            );
        }
    }

    /// Match two complementary orders that have a profitable spread.
    /// NOTE: (leftOrder.makerAmount / leftOrder.takerAmount) should be always greater than or equal to
    /// (rightOrder.takerAmount / rightOrder.makerAmount).
    /// @param leftOrder First order object to match.
    /// @param rightOrder Second order object to match.
    /// @param spreadReceiver Address to receive a profitable spread.
    /// @param results Fill results of matched orders and spread amount.
    function matchOrders(
        Common.Order memory leftOrder,
        Common.Order memory rightOrder,
        address spreadReceiver
    )
    public
    nonReentrant
    returns (Common.MatchedFillResults memory results)
    {
        // Matching orders pre-check.
        require(
            leftOrder.makerToken == rightOrder.takerToken &&
            leftOrder.takerToken == rightOrder.makerToken &&
            mul(leftOrder.makerAmount, rightOrder.makerAmount) >= mul(leftOrder.takerAmount, rightOrder.takerAmount),
            "UNMATCHED_ORDERS"
        );
        Common.OrderInfo memory leftOrderInfo = getOrderInfo(leftOrder);
        Common.OrderInfo memory rightOrderInfo = getOrderInfo(rightOrder);
        results = calculateMatchedFillResults(
            leftOrder,
            rightOrder,
            leftOrderInfo.filledTakerAmount,
            rightOrderInfo.filledTakerAmount
        );
        assertFillableOrder(
            leftOrder,
            leftOrderInfo,
            msg.sender,
            results.left.takerFilledAmount
        );
        assertFillableOrder(
            rightOrder,
            rightOrderInfo,
            msg.sender,
            results.right.takerFilledAmount
        );
        settleMatchedOrders(leftOrder, rightOrder, results, spreadReceiver);
        filled[leftOrderInfo.orderHash] = add(leftOrderInfo.filledTakerAmount, results.left.takerFilledAmount);
        filled[rightOrderInfo.orderHash] = add(rightOrderInfo.filledTakerAmount, results.right.takerFilledAmount);
        emitFillOrderEvent(leftOrderInfo.orderHash, leftOrder, results.left);
        emitFillOrderEvent(rightOrderInfo.orderHash, rightOrder, results.right);
        return results;
    }

    /// Given a list of orders, fill them in sequence until total taker amount is reached.
    /// NOTE: All orders should be in the same token pair.
    /// @param orderList Array of order objects.
    /// @param totalTakerAmountToFill Stop filling when the total taker amount is reached.
    /// @return totalFillResults Total amounts filled and fees paid by maker and taker.
    function marketTakerOrders(
        Common.Order[] memory orderList,
        uint256 totalTakerAmountToFill
    )
    public
    returns (Common.FillResults memory totalFillResults)
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            Common.FillResults memory singleFillResults = fillOrderNoThrow(
                orderList[i],
                sub(totalTakerAmountToFill, totalFillResults.takerFilledAmount),
                true
            );
            addFillResults(totalFillResults, singleFillResults);
            if (totalFillResults.takerFilledAmount >= totalTakerAmountToFill) {
                break;
            }
        }
        return totalFillResults;
    }

    /// Given a list of orders, fill them in sequence until total maker amount is reached.
    /// NOTE: All orders should be in the same token pair.
    /// @param orderList Array of order objects.
    /// @param totalMakerAmountToFill Stop filling when the total maker amount is reached.
    /// @return totalFillResults Total amounts filled and fees paid by maker and taker.
    function marketMakerOrders(
        Common.Order[] memory orderList,
        uint256 totalMakerAmountToFill
    )
    public
    returns (Common.FillResults memory totalFillResults)
    {
        for (uint256 i = 0; i < orderList.length; i++) {
            Common.FillResults memory singleFillResults = fillOrderNoThrow(
                orderList[i],
                getPartialAmountFloor(
                    orderList[i].takerAmount, orderList[i].makerAmount,
                    sub(totalMakerAmountToFill, totalFillResults.makerFilledAmount)
                ),
                true
            );
            addFillResults(totalFillResults, singleFillResults);
            if (totalFillResults.makerFilledAmount >= totalMakerAmountToFill) {
                break;
            }
        }
        return totalFillResults;
    }

    /// Gets information about an order.
    /// @param order Order object.
    /// @return orderInfo Information about the order status, order hash, and filled amount.
    function getOrderInfo(Common.Order memory order)
    public
    view
    returns (Common.OrderInfo memory orderInfo)
    {
        orderInfo.orderHash = getOrderHash(order);
        orderInfo.filledTakerAmount = filled[orderInfo.orderHash];
        if (
            !whitelists[uint8(WhitelistType.RESELLER)][order.reseller] ||
            !whitelists[uint8(WhitelistType.VERIFIER)][order.verifier] ||
            !whitelists[uint8(WhitelistType.BANK)][order.makerTokenBank] ||
            !whitelists[uint8(WhitelistType.BANK)][order.takerTokenBank]
        ) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID);
            return orderInfo;
        }

        if (!isValidSignature(orderInfo.orderHash, order.maker, order.signature)) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID_SIGNATURE);
            return orderInfo;
        }

        if (order.makerAmount == 0) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID_MAKER_AMOUNT);
            return orderInfo;
        }
        if (order.takerAmount == 0) {
            orderInfo.orderStatus = uint8(OrderStatus.INVALID_TAKER_AMOUNT);
            return orderInfo;
        }
        if (orderInfo.filledTakerAmount >= order.takerAmount) {
            orderInfo.orderStatus = uint8(OrderStatus.FULLY_FILLED);
            return orderInfo;
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= order.expires) {
            orderInfo.orderStatus = uint8(OrderStatus.EXPIRED);
            return orderInfo;
        }
        if (cancelled[orderInfo.orderHash]) {
            orderInfo.orderStatus = uint8(OrderStatus.CANCELLED);
            return orderInfo;
        }
        orderInfo.orderStatus = uint8(OrderStatus.FILLABLE);
        return orderInfo;
    }

    /// Calculates hash of an order.
    /// @param order Order object.
    /// @return Hash of order.
    function getOrderHash(Common.Order memory order)
    public
    view
    returns (bytes32)
    {
        bytes memory part1 = abi.encodePacked(
            address(this),
            order.maker,
            order.taker,
            order.makerToken,
            order.takerToken,
            order.makerTokenBank,
            order.takerTokenBank,
            order.reseller,
            order.verifier
        );
        bytes memory part2 = abi.encodePacked(
            order.makerAmount,
            order.takerAmount,
            order.expires,
            order.nonce,
            order.minimumTakerAmount,
            order.makerData,
            order.takerData
        );
        return keccak256(abi.encodePacked(part1, part2));
    }

    /// Cancels an order.
    /// @param order Order object.
    function cancelOrderInternal(
        Common.Order memory order
    )
    internal
    {
        Common.OrderInfo memory orderInfo = getOrderInfo(order);
        require(orderInfo.orderStatus == uint8(OrderStatus.FILLABLE), "ORDER_UNFILLABLE");
        require(order.maker == msg.sender, "INVALID_MAKER");
        cancelled[orderInfo.orderHash] = true;
        emit CancelOrder(
            orderInfo.orderHash,
            order.maker,
            order.makerToken,
            order.takerToken,
            order.reseller,
            order.makerAmount,
            order.takerAmount,
            order.makerData,
            order.takerData
        );
    }

    /// Fills an order.
    /// @param order Order object.
    /// @param takerAmountToFill Desired amount of takerToken to sell.
    /// @param allowInsufficient Whether insufficient order remaining is allowed to fill.
    /// @return results Amounts filled and fees paid by maker and taker.
    function fillOrderInternal(
        Common.Order memory order,
        uint256 takerAmountToFill,
        bool allowInsufficient
    )
    internal
    returns (Common.FillResults memory results)
    {
        require(takerAmountToFill > 0, "INVALID_TAKER_AMOUNT");
        Common.OrderInfo memory orderInfo = getOrderInfo(order);
        uint256 remainingTakerAmount = sub(order.takerAmount, orderInfo.filledTakerAmount);
        if (allowInsufficient) {
            takerAmountToFill = min(takerAmountToFill, remainingTakerAmount);
        } else {
            require(takerAmountToFill <= remainingTakerAmount, "INSUFFICIENT_ORDER_REMAINING");
        }
        assertFillableOrder(
            order,
            orderInfo,
            msg.sender,
            takerAmountToFill
        );
        results = settleOrder(order, takerAmountToFill);
        filled[orderInfo.orderHash] = add(orderInfo.filledTakerAmount, results.takerFilledAmount);
        emitFillOrderEvent(orderInfo.orderHash, order, results);
        return results;
    }

    /// Emits a FillOrder event.
    /// @param orderHash Hash of order.
    /// @param order Order object.
    /// @param results Order fill results.
    function emitFillOrderEvent(
        bytes32 orderHash,
        Common.Order memory order,
        Common.FillResults memory results
    )
    internal
    {
        emit FillOrder(
            orderHash,
            order.maker,
            msg.sender,
            order.makerToken,
            order.takerToken,
            order.reseller,
            results.makerFilledAmount,
            results.makerFeeExchange,
            results.makerFeeReseller,
            results.takerFilledAmount,
            results.takerFeeExchange,
            results.takerFeeReseller,
            order.makerData,
            order.takerData
        );
    }

    /// Validates context for fillOrder. Succeeds or throws.
    /// @param order Order object to be filled.
    /// @param orderInfo Information about the order status, order hash, and amount already filled of order.
    /// @param taker Address of order taker.
    /// @param takerAmountToFill Desired amount of takerToken to sell.
    function assertFillableOrder(
        Common.Order memory order,
        Common.OrderInfo memory orderInfo,
        address taker,
        uint256 takerAmountToFill
    )
    view
    internal
    {
        // An order can only be filled if its status is FILLABLE.
        require(orderInfo.orderStatus == uint8(OrderStatus.FILLABLE), "ORDER_UNFILLABLE");

        // Validate taker is allowed to fill this order.
        if (order.taker != address(0)) {
            require(order.taker == taker, "INVALID_TAKER");
        }

        // Validate minimum taker amount.
        if (order.minimumTakerAmount > 0) {
            require(takerAmountToFill >= order.minimumTakerAmount, "ORDER_MINIMUM_UNREACHED");
        }

        // Go through Verifier.
        if (order.verifier != address(0)) {
            require(Verifier(order.verifier).verify(order, takerAmountToFill, msg.sender), "FAILED_VALIDATION");
        }
    }

    /// Verifies that an order signature is valid.
    /// @param hash Message hash that is signed.
    /// @param signer Address of signer.
    /// @param signature Order signature.
    /// @return Validity of order signature.
    function isValidSignature(
        bytes32 hash,
        address signer,
        bytes memory signature
    )
    internal
    pure
    returns (bool)
    {
        uint8 v = uint8(signature[0]);
        bytes32 r = signature.readBytes32(1);
        bytes32 s = signature.readBytes32(33);
        return signer == ecrecover(
            keccak256(abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                hash
            )),
            v,
            r,
            s
        );
    }

    /// Adds properties of a single FillResults to total FillResults.
    /// @param totalFillResults Fill results instance that will be added onto.
    /// @param singleFillResults Fill results instance that will be added to totalFillResults.
    function addFillResults(
        Common.FillResults memory totalFillResults,
        Common.FillResults memory singleFillResults
    )
    internal
    pure
    {
        totalFillResults.makerFilledAmount = add(totalFillResults.makerFilledAmount, singleFillResults.makerFilledAmount);
        totalFillResults.makerFeeExchange = add(totalFillResults.makerFeeExchange, singleFillResults.makerFeeExchange);
        totalFillResults.makerFeeReseller = add(totalFillResults.makerFeeReseller, singleFillResults.makerFeeReseller);
        totalFillResults.takerFilledAmount = add(totalFillResults.takerFilledAmount, singleFillResults.takerFilledAmount);
        totalFillResults.takerFeeExchange = add(totalFillResults.takerFeeExchange, singleFillResults.takerFeeExchange);
        totalFillResults.takerFeeReseller = add(totalFillResults.takerFeeReseller, singleFillResults.takerFeeReseller);
    }

    /// Settles an order by swapping funds and paying fees.
    /// @param order Order object.
    /// @param takerAmountToFill Desired amount of takerToken to sell.
    /// @param results Amounts to be filled and fees paid by maker and taker.
    function settleOrder(
        Common.Order memory order,
        uint256 takerAmountToFill
    )
    internal
    returns (Common.FillResults memory results)
    {
        results.takerFilledAmount = takerAmountToFill;
        results.makerFilledAmount = safeGetPartialAmountFloor(order.makerAmount, order.takerAmount, results.takerFilledAmount);
        // Calculate maker fees if makerTokenBank is non-fee-exempt.
        if (!whitelists[uint8(WhitelistType.FEE_EXEMPT_BANK)][order.makerTokenBank]) {
            if (fees[order.reseller][0] > 0) {
                results.makerFeeExchange = mul(results.makerFilledAmount, fees[order.reseller][0]) / (1 ether);
            }
            if (fees[order.reseller][1] > 0) {
                results.makerFeeReseller = mul(results.makerFilledAmount, fees[order.reseller][1]) / (1 ether);
            }
        }
        // Calculate taker fees if takerTokenBank is non-fee-exempt.
        if (!whitelists[uint8(WhitelistType.FEE_EXEMPT_BANK)][order.takerTokenBank]) {
            if (fees[order.reseller][2] > 0) {
                results.takerFeeExchange = mul(results.takerFilledAmount, fees[order.reseller][2]) / (1 ether);
            }
            if (fees[order.reseller][3] > 0) {
                results.takerFeeReseller = mul(results.takerFilledAmount, fees[order.reseller][3]) / (1 ether);
            }
        }
        if (results.makerFeeExchange > 0) {
            // Transfer maker fee to exchange fee account.
            IBank(order.makerTokenBank).transferFrom(
                order.makerToken,
                order.maker,
                feeAccount,
                results.makerFeeExchange,
                order.makerData,
                true,
                false
            );
        }
        if (results.makerFeeReseller > 0) {
            // Transfer maker fee to reseller fee account.
            IBank(order.makerTokenBank).transferFrom(
                order.makerToken,
                order.maker,
                order.reseller,
                results.makerFeeReseller,
                order.makerData,
                true,
                false
            );
        }
        if (results.takerFeeExchange > 0) {
            // Transfer taker fee to exchange fee account.
            IBank(order.takerTokenBank).transferFrom(
                order.takerToken,
                msg.sender,
                feeAccount,
                results.takerFeeExchange,
                order.takerData,
                true,
                false
            );
        }
        if (results.takerFeeReseller > 0) {
            // Transfer taker fee to reseller fee account.
            IBank(order.takerTokenBank).transferFrom(
                order.takerToken,
                msg.sender,
                order.reseller,
                results.takerFeeReseller,
                order.takerData,
                true,
                false
            );
        }
        // Transfer tokens from maker to taker.
        IBank(order.makerTokenBank).transferFrom(
            order.makerToken,
            order.maker,
            msg.sender,
            results.makerFilledAmount,
            order.makerData,
            true,
            true
        );
        // Transfer tokens from taker to maker.
        IBank(order.takerTokenBank).transferFrom(
            order.takerToken,
            msg.sender,
            order.maker,
            results.takerFilledAmount,
            order.takerData,
            true,
            true
        );
    }

    /// Calculates fill amounts for matched orders that have a profitable spread.
    /// NOTE: (leftOrder.makerAmount / leftOrder.takerAmount) should be always greater than or equal to
    /// (rightOrder.takerAmount / rightOrder.makerAmount).
    /// @param leftOrder First order object to match.
    /// @param rightOrder Second order object to match.
    /// @param leftFilledTakerAmount Amount of left order already filled.
    /// @param rightFilledTakerAmount Amount of right order already filled.
    /// @param results Fill results of matched orders and spread amount.
    function calculateMatchedFillResults(
        Common.Order memory leftOrder,
        Common.Order memory rightOrder,
        uint256 leftFilledTakerAmount,
        uint256 rightFilledTakerAmount
    )
    internal
    view
    returns (Common.MatchedFillResults memory results)
    {
        uint256 leftRemainingTakerAmount = sub(leftOrder.takerAmount, leftFilledTakerAmount);
        uint256 leftRemainingMakerAmount = safeGetPartialAmountFloor(
            leftOrder.makerAmount,
            leftOrder.takerAmount,
            leftRemainingTakerAmount
        );
        uint256 rightRemainingTakerAmount = sub(rightOrder.takerAmount, rightFilledTakerAmount);
        uint256 rightRemainingMakerAmount = safeGetPartialAmountFloor(
            rightOrder.makerAmount,
            rightOrder.takerAmount,
            rightRemainingTakerAmount
        );

        if (leftRemainingTakerAmount >= rightRemainingMakerAmount) {
            // Case 1: Right order is fully filled.
            results.right.makerFilledAmount = rightRemainingMakerAmount;
            results.right.takerFilledAmount = rightRemainingTakerAmount;
            results.left.takerFilledAmount = results.right.makerFilledAmount;
            // Round down to ensure the maker's exchange rate does not exceed the price specified by the order.
            // We favor the maker when the exchange rate must be rounded.
            results.left.makerFilledAmount = safeGetPartialAmountFloor(
                leftOrder.makerAmount,
                leftOrder.takerAmount,
                results.left.takerFilledAmount
            );
        } else {
            // Case 2: Left order is fully filled.
            results.left.makerFilledAmount = leftRemainingMakerAmount;
            results.left.takerFilledAmount = leftRemainingTakerAmount;
            results.right.makerFilledAmount = results.left.takerFilledAmount;
            // Round up to ensure the maker's exchange rate does not exceed the price specified by the order.
            // We favor the maker when the exchange rate must be rounded.
            results.right.takerFilledAmount = safeGetPartialAmountCeil(
                rightOrder.takerAmount,
                rightOrder.makerAmount,
                results.right.makerFilledAmount
            );
        }
        results.spreadAmount = sub(
            results.left.makerFilledAmount,
            results.right.takerFilledAmount
        );
        if (!whitelists[uint8(WhitelistType.FEE_EXEMPT_BANK)][leftOrder.makerTokenBank]) {
            if (fees[leftOrder.reseller][0] > 0) {
                results.left.makerFeeExchange = mul(results.left.makerFilledAmount, fees[leftOrder.reseller][0]) / (1 ether);
            }
            if (fees[leftOrder.reseller][1] > 0) {
                results.left.makerFeeReseller = mul(results.left.makerFilledAmount, fees[leftOrder.reseller][1]) / (1 ether);
            }
        }
        if (!whitelists[uint8(WhitelistType.FEE_EXEMPT_BANK)][rightOrder.makerTokenBank]) {
            if (fees[rightOrder.reseller][2] > 0) {
                results.right.makerFeeExchange = mul(results.right.makerFilledAmount, fees[rightOrder.reseller][2]) / (1 ether);
            }
            if (fees[rightOrder.reseller][3] > 0) {
                results.right.makerFeeReseller = mul(results.right.makerFilledAmount, fees[rightOrder.reseller][3]) / (1 ether);
            }
        }
        return results;
    }

    /// Settles matched order by swapping funds, paying fees and transferring spread.
    /// @param leftOrder First matched order object.
    /// @param rightOrder Second matched order object.
    /// @param results Fill results of matched orders and spread amount.
    /// @param spreadReceiver Address to receive a profitable spread.
    function settleMatchedOrders(
        Common.Order memory leftOrder,
        Common.Order memory rightOrder,
        Common.MatchedFillResults memory results,
        address spreadReceiver
    )
    internal
    {
        if (results.left.makerFeeExchange > 0) {
            // Transfer left maker fee to exchange fee account.
            IBank(leftOrder.makerTokenBank).transferFrom(
                leftOrder.makerToken,
                leftOrder.maker,
                feeAccount,
                results.left.makerFeeExchange,
                leftOrder.makerData,
                true,
                false
            );
        }
        if (results.left.makerFeeReseller > 0) {
            // Transfer left maker fee to reseller fee account.
            IBank(leftOrder.makerTokenBank).transferFrom(
                leftOrder.makerToken,
                leftOrder.maker,
                leftOrder.reseller,
                results.left.makerFeeReseller,
                leftOrder.makerData,
                true,
                false
            );
        }
        if (results.right.makerFeeExchange > 0) {
            // Transfer right maker fee to exchange fee account.
            IBank(rightOrder.makerTokenBank).transferFrom(
                rightOrder.makerToken,
                rightOrder.maker,
                feeAccount,
                results.right.makerFeeExchange,
                rightOrder.makerData,
                true,
                false
            );
        }
        if (results.right.makerFeeReseller > 0) {
            // Transfer right maker fee to reseller fee account.
            IBank(rightOrder.makerTokenBank).transferFrom(
                rightOrder.makerToken,
                rightOrder.maker,
                rightOrder.reseller,
                results.right.makerFeeReseller,
                rightOrder.makerData,
                true,
                false
            );
        }
        // Note that there's no taker fees for matched orders.

        // Transfer tokens from left order maker to right order maker.
        IBank(leftOrder.makerTokenBank).transferFrom(
            leftOrder.makerToken,
            leftOrder.maker,
            rightOrder.maker,
            results.right.takerFilledAmount,
            leftOrder.makerData,
            true,
            true
        );
        // Transfer tokens from right order maker to left order maker.
        IBank(rightOrder.makerTokenBank).transferFrom(
            rightOrder.makerToken,
            rightOrder.maker,
            leftOrder.maker,
            results.left.takerFilledAmount,
            rightOrder.makerData,
            true,
            true
        );
        if (results.spreadAmount > 0) {
            // Transfer spread to spread receiver.
            IBank(leftOrder.makerTokenBank).transferFrom(
                leftOrder.makerToken,
                leftOrder.maker,
                spreadReceiver,
                results.spreadAmount,
                leftOrder.makerData,
                true,
                false
            );
        }
    }
}