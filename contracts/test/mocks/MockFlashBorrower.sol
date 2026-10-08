// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

interface IPoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf) external returns (uint256);
}

contract MockFlashBorrower is IERC3156FlashBorrower {
    enum Mode {
        Repay,
        NoRepay,
        BadReturn,
        Reenter
    }

    address public immutable lender;
    Mode public mode;

    constructor(address lender_) {
        lender = lender_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == lender, "lender");
        if (mode == Mode.Reenter) {
            IERC20(token).approve(lender, amount);
            IPoolLike(lender).supply(token, amount, address(this));
        }
        if (mode == Mode.BadReturn) return bytes32(0);
        if (mode != Mode.NoRepay) IERC20(token).approve(lender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
