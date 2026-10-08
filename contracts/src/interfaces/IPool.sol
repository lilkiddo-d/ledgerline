// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";

interface IPool {
    // ---- events ----
    event ReserveInitialized(address indexed asset, address receiptToken, address debtToken, uint8 id);
    event Supply(address indexed asset, address indexed caller, address indexed onBehalfOf, uint256 amount, uint256 shares);
    event Withdraw(address indexed asset, address indexed owner, address indexed to, uint256 amount, uint256 shares);
    event Borrow(address indexed asset, address indexed borrower, uint256 amount, uint256 shares, uint256 rateRay);
    event Repay(address indexed asset, address indexed payer, address indexed onBehalfOf, uint256 amount, uint256 shares);
    event CollateralToggled(address indexed asset, address indexed user, bool enabled);
    event EModeSet(address indexed user, uint8 category);
    event Liquidation(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        address liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 protocolFee,
        bool receiveReceipt
    );
    event BadDebtWrittenOff(address indexed asset, address indexed user, uint256 amount, uint256 coveredByReserve, uint256 socialized);
    event FlashLoan(address indexed receiver, address indexed initiator, address indexed asset, uint256 amount, uint256 fee);
    event ReserveAccrued(address indexed asset, uint256 liquidityIndex, uint256 borrowIndex, uint256 borrowRateRay);
    event MintedToTreasury(address indexed asset, uint256 shares);
    event BorrowDiscountApplied(address indexed asset, address indexed user, uint256 amount);
    event ReserveFlagsUpdated(address indexed asset, bool frozen, bool paused);
    event ModuleUpdated(bytes32 indexed key, address value);
    event FlashFeeUpdated(uint256 bps);
    event Skimmed(address indexed asset, address to, uint256 amount);

    // ---- user actions ----
    function supply(address asset, uint256 amount, address onBehalfOf) external returns (uint256 shares);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);
    function borrow(address asset, uint256 amount) external returns (uint256 shares);
    function repay(address asset, uint256 amount, address onBehalfOf) external returns (uint256 repaid);
    function setUseAsCollateral(address asset, bool enabled) external;
    function setEMode(uint8 category) external;
    function liquidate(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveReceipt)
        external
        returns (uint256 debtRepaid, uint256 collateralSeized);
    function accrue(address asset) external;

    // ---- hooks from receipt tokens ----
    function finalizeTransfer(address asset, address from, address to, uint256 shares) external;
    function vaultWithdraw(address asset, address owner, address receiver, uint256 amount, bool sharesMode)
        external
        returns (uint256 assets, uint256 shares);

    // ---- views ----
    function getReserveData(address asset) external view returns (Types.ReserveData memory);
    function getReservesList() external view returns (address[] memory);
    function getNormalizedIncome(address asset) external view returns (uint256);
    function getNormalizedDebt(address asset) external view returns (uint256);
    function totalSupplyAssets(address asset) external view returns (uint256);
    function totalDebt(address asset) external view returns (uint256);
    function getUserAccountData(address user) external view returns (Types.AccountData memory);
    function getUserConfig(address user) external view returns (uint256);
    function getUserEMode(address user) external view returns (uint8);
}
