// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MathLib} from "../libraries/MathLib.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IPool} from "../interfaces/IPool.sol";

/// @title DebtToken
/// @notice Non-transferable variable-debt tracker. Stores scaled debt; `balanceOf` returns
///         scaled * borrowIndex, rounded up (against the borrower).
contract DebtToken {
    using MathLib for uint256;

    IPool public immutable POOL;
    address public immutable UNDERLYING;
    uint8 public immutable decimals;
    string public name;
    string public symbol;

    uint256 public scaledTotalSupply;
    mapping(address => uint256) public scaledBalanceOf;
    /// @notice borrow index at the user's last debt interaction (used for staker discounts)
    mapping(address => uint256) public userIndex;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Mint(address indexed user, uint256 scaled, uint256 index);
    event Burn(address indexed user, uint256 scaled, uint256 index);
    event UserIndexUpdated(address indexed user, uint256 index);

    modifier onlyPool() {
        if (msg.sender != address(POOL)) revert LLErrors.OnlyPool();
        _;
    }

    constructor(IPool pool_, address underlying_, uint8 decimals_, string memory name_, string memory symbol_) {
        if (address(pool_) == address(0) || underlying_ == address(0)) revert LLErrors.ZeroAddress();
        POOL = pool_;
        UNDERLYING = underlying_;
        decimals = decimals_;
        name = name_;
        symbol = symbol_;
    }

    function mintScaled(address user, uint256 scaled, uint256 index) external onlyPool {
        scaledBalanceOf[user] += scaled;
        scaledTotalSupply += scaled;
        userIndex[user] = index;
        emit Mint(user, scaled, index);
        emit Transfer(address(0), user, scaled.rayMulUp(index));
    }

    function burnScaled(address user, uint256 scaled, uint256 index) external onlyPool {
        scaledBalanceOf[user] -= scaled;
        scaledTotalSupply -= scaled;
        emit Burn(user, scaled, index);
        emit Transfer(user, address(0), scaled.rayMulDown(index));
    }

    function setUserIndex(address user, uint256 index) external onlyPool {
        userIndex[user] = index;
        emit UserIndexUpdated(user, index);
    }

    function balanceOf(address user) external view returns (uint256) {
        return scaledBalanceOf[user].rayMulUp(POOL.getNormalizedDebt(UNDERLYING));
    }

    function totalSupply() external view returns (uint256) {
        return scaledTotalSupply.rayMulUp(POOL.getNormalizedDebt(UNDERLYING));
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert LLErrors.NotTransferable();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert LLErrors.NotTransferable();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert LLErrors.NotTransferable();
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}
