// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import {PoolBase} from "./PoolBase.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {Types} from "../libraries/Types.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IPool} from "../interfaces/IPool.sol";

/// @title FlashLoan
/// @notice Delegatecall module of the Pool implementing ERC-3156 flash loans with a fee.
/// @dev The Pool's reentrancy lock is held for the whole loan, so the borrower cannot touch Pool
///      state (supply, borrow, liquidate...) from inside the callback. The fee is credited to the
///      protocol treasury accrual before any external call (checks-effects-interactions).
contract FlashLoan is PoolBase {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    address private immutable SELF = address(this);

    // ERC-3156: repayment is pulled from the receiver that approved it and returned CALLBACK_SUCCESS.
    // slither-disable-start arbitrary-send-erc20
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data, address initiator) external {
        if (address(this) == SELF) revert LLErrors.OnlyDelegateCall();
        if (amount == 0) revert LLErrors.ZeroAmount();
        if (receiver == address(0)) revert LLErrors.ZeroAddress();
        Types.ReserveData storage r = _reserve(token);
        if (r.paused) revert LLErrors.ReservePaused();
        _checkCompliance(initiator, Types.ACTION_FLASHLOAN);
        if (amount > r.cash) revert LLErrors.InsufficientLiquidity();
        _accrue(token, r);

        uint256 fee = amount.bpsMulUp(_s().flashFeeBps);
        // Effects: the loan is net-zero on cash once repaid; only the fee changes accounting.
        r.cash += uint128(fee);
        r.accruedToTreasuryScaled += uint128(fee.rayDivDown(r.liquidityIndex));
        _updateRate(token, r);
        emit IPool.FlashLoan(receiver, initiator, token, amount, fee);

        // Interactions
        IERC20(token).safeTransfer(receiver, amount);
        if (IERC3156FlashBorrower(receiver).onFlashLoan(initiator, token, amount, fee, data) != CALLBACK_SUCCESS) {
            revert LLErrors.FlashLoanCallbackFailed();
        }
        // ERC-3156: the receiver approved repayment and returned CALLBACK_SUCCESS, so pulling from it is the spec.
        IERC20(token).safeTransferFrom(receiver, address(this), amount + fee);
    }
    // slither-disable-end arbitrary-send-erc20
}
