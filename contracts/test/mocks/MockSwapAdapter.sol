// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Swaps at a fixed rate (out per 1e18 in), minting the output token.
contract MockSwapAdapter {
    uint256 public rate;

    function setRate(uint256 r) external {
        rate = r;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline)
        external
        returns (uint256 out)
    {
        require(block.timestamp <= deadline, "deadline");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * rate / 1e18;
        require(out >= minOut, "slippage");
        MockERC20(tokenOut).mint(recipient, out);
    }
}
