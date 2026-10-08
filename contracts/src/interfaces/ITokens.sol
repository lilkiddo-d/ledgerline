// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Pool-facing surface of the receipt (supply share) token.
interface IReceiptToken {
    function mintShares(address to, uint256 shares) external;
    function burnShares(address from, uint256 shares) external;
    function poolTransfer(address from, address to, uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Pool-facing surface of the variable debt token.
interface IDebtToken {
    function mintScaled(address user, uint256 scaled, uint256 index) external;
    function burnScaled(address user, uint256 scaled, uint256 index) external;
    function setUserIndex(address user, uint256 index) external;
    function scaledBalanceOf(address user) external view returns (uint256);
    function scaledTotalSupply() external view returns (uint256);
    function userIndex(address user) external view returns (uint256);
}
