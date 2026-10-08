// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Custom errors shared across the protocol.
library LLErrors {
    error ZeroAddress();
    error ZeroAmount();
    error InvalidParams();
    error ReserveNotActive();
    error ReserveFrozen();
    error ReservePaused();
    error ReserveAlreadyListed();
    error TooManyReserves();
    error SupplyCapExceeded();
    error BorrowCapExceeded();
    error ClosedMarketBorrowCapExceeded();
    error BorrowingDisabled();
    error CollateralDisabled();
    error InsufficientLiquidity();
    error InsufficientBalance();
    error InsufficientCollateral();
    error HealthyAccount();
    error NoDebt();
    error NoCollateral();
    error EModeMismatch();
    error NotCompliant();
    error OnlyPool();
    error OnlyReceiptToken();
    error OnlyDelegateCall();
    error FlashLoanCallbackFailed();
    error StalePrice();
    error InvalidPrice();
    error PriceDeviation();
    error SequencerDown();
    error FeedNotSet();
    error AlreadySet();
    error NotActive();
    error Cooldown();
    error DeadlineExpired();
    error SlippageTooHigh();
    error NotTransferable();
}
