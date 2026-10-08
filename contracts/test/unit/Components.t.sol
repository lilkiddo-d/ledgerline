// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";
import {ReceiptToken} from "../../src/core/ReceiptToken.sol";
import {DebtToken} from "../../src/core/DebtToken.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {AssetConfig} from "../../src/core/AssetConfig.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IAssetConfig} from "../../src/interfaces/IAssetConfig.sol";

contract FlashLoanTest is BaseTest {
    MockFlashBorrower internal fb;

    function setUp() public override {
        super.setUp();
        _supply(alice, usdg, 100_000e6);
        fb = new MockFlashBorrower(address(d.pool));
        usdg.mint(address(fb), 1_000e6); // to pay fees
    }

    function test_flashLoan_feeToTreasury() public {
        uint256 cashBefore = d.pool.getReserveData(address(usdg)).cash;
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 50_000e6, "");
        uint256 fee = 25e6; // 5 bps
        Types.ReserveData memory r = d.pool.getReserveData(address(usdg));
        assertEq(r.cash, cashBefore + fee);
        assertEq(usdg.balanceOf(address(d.pool)), cashBefore + fee);
        assertEq(r.accruedToTreasuryScaled, fee);
    }

    function test_flashLoan_failures() public {
        fb.setMode(MockFlashBorrower.Mode.NoRepay);
        vm.expectRevert();
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 1_000e6, "");
        fb.setMode(MockFlashBorrower.Mode.BadReturn);
        vm.expectRevert(LLErrors.FlashLoanCallbackFailed.selector);
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 1_000e6, "");
        fb.setMode(MockFlashBorrower.Mode.Reenter); // pool is locked during the callback
        vm.expectRevert();
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 1_000e6, "");
        fb.setMode(MockFlashBorrower.Mode.Repay);
        vm.expectRevert(LLErrors.InsufficientLiquidity.selector);
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 100_001e6, "");
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 0, "");
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.pool.flashLoan(IERC3156FlashBorrower(address(0)), address(usdg), 1, "");
        d.pool.setReserveFlags(address(usdg), false, true);
        vm.expectRevert(LLErrors.ReservePaused.selector);
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 1, "");
    }

    function test_flashLoan_compliance() public {
        d.compliance.setEnabled(true);
        vm.expectRevert(LLErrors.NotCompliant.selector);
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(usdg), 1e6, "");
    }

    function test_module_direct() public {
        vm.expectRevert(LLErrors.OnlyDelegateCall.selector);
        d.flashLoanModule.flashLoan(address(fb), address(usdg), 1, "", address(this));
    }
}

contract ReceiptTokenTest is BaseTest {
    ReceiptToken internal rt;

    function setUp() public override {
        super.setUp();
        rt = _rt(address(usdg));
        usdg.mint(alice, 10_000e6);
        vm.prank(alice);
        usdg.approve(address(rt), type(uint256).max);
    }

    function test_metadata() public view {
        assertEq(rt.decimals(), 6);
        assertEq(rt.asset(), address(usdg));
        assertEq(rt.symbol(), "llUSDG");
    }

    function test_erc4626_flow() public {
        vm.prank(alice);
        uint256 shares = rt.deposit(1_000e6, alice);
        assertEq(shares, 1_000e6);
        assertEq(rt.totalAssets(), 1_000e6);
        assertEq(rt.convertToAssets(shares), 1_000e6);
        assertEq(rt.previewDeposit(1e6), 1e6);
        assertEq(rt.previewRedeem(1e6), 1e6);
        assertEq(rt.previewMint(1e6), 1e6);
        assertEq(rt.previewWithdraw(1e6), 1e6);
        assertEq(rt.balanceOfAssets(alice), 1_000e6);
        assertEq(rt.maxDeposit(alice), type(uint256).max);
        assertEq(rt.maxMint(alice), type(uint256).max);
        assertEq(rt.maxWithdraw(alice), 1_000e6);
        assertEq(rt.maxRedeem(alice), 1_000e6);

        vm.prank(alice);
        rt.mint(500e6, alice);
        vm.prank(alice);
        rt.withdraw(300e6, bob, alice);
        assertEq(usdg.balanceOf(bob), 300e6);
        vm.prank(alice);
        uint256 got = rt.redeem(200e6, bob, alice);
        assertEq(got, 200e6);

        // third-party withdraw needs allowance
        vm.prank(carol);
        vm.expectRevert();
        rt.withdraw(1e6, carol, alice);
        vm.prank(alice);
        rt.approve(carol, 20e6);
        vm.prank(carol);
        rt.withdraw(10e6, carol, alice);
        vm.prank(carol);
        rt.redeem(10e6, carol, alice);
        assertEq(rt.allowance(alice, carol), 0);
    }

    function test_maxDeposit_respectsCapAndFlags() public {
        _setParams(address(usdg), _stableParams(100e6, 0));
        assertEq(rt.maxDeposit(alice), 100e6);
        assertEq(rt.maxMint(alice), 100e6);
        vm.prank(alice);
        rt.deposit(100e6, alice);
        assertEq(rt.maxDeposit(alice), 0);
        d.pool.setReserveFlags(address(usdg), false, true);
        assertEq(rt.maxDeposit(alice), 0);
        assertEq(rt.maxWithdraw(alice), 0);
    }

    function test_onlyPool() public {
        vm.expectRevert(LLErrors.OnlyPool.selector);
        rt.mintShares(alice, 1);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        rt.burnShares(alice, 1);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        rt.poolTransfer(alice, bob, 1);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new ReceiptToken(IPool(address(0)), d.assetConfig, address(usdg), "x", "x");
    }

    function test_exchangeRate_grows_and_redeemsAtLeastShare() public {
        vm.prank(alice);
        rt.deposit(10_000e6, alice);
        _supply(bob, aapl, 1_000e18);
        _borrow(bob, usdg, 9_000e6);
        _warpBy(180 days);
        assertGt(rt.convertToAssets(1e6), 1e6);
        usdg.mint(bob, 2_000e6);
        vm.prank(bob);
        d.pool.repay(address(usdg), type(uint256).max, bob);
        uint256 owed = rt.convertToAssets(rt.balanceOf(alice));
        vm.prank(alice);
        uint256 got = d.pool.withdraw(address(usdg), type(uint256).max, alice);
        assertEq(got, owed);
        assertGt(got, 10_000e6);
    }
}

contract DebtTokenTest is BaseTest {
    function test_debtToken_nonTransferable() public {
        DebtToken dt = _dt(address(usdg));
        assertEq(dt.decimals(), 6);
        assertEq(dt.allowance(alice, bob), 0);
        vm.expectRevert(LLErrors.NotTransferable.selector);
        dt.transfer(bob, 1);
        vm.expectRevert(LLErrors.NotTransferable.selector);
        dt.transferFrom(alice, bob, 1);
        vm.expectRevert(LLErrors.NotTransferable.selector);
        dt.approve(bob, 1);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        dt.mintScaled(alice, 1, 1);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        dt.burnScaled(alice, 1, 1);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        dt.setUserIndex(alice, 1);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new DebtToken(IPool(address(0)), address(usdg), 6, "x", "x");
    }

    function test_debtToken_totalSupply() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 100e18);
        _borrow(bob, usdg, 1_000e6);
        assertEq(_dt(address(usdg)).totalSupply(), 1_000e6);
        _warpBy(10 days);
        assertGt(_dt(address(usdg)).totalSupply(), 1_000e6);
    }
}

contract InterestRateModelTest is BaseTest {
    function test_kinkedModel() public {
        InterestRateModel m = d.stableIrm; // 0 base, 6% @ 90%, +60%
        assertEq(m.getBorrowRate(100, 0), 0);
        assertEq(m.utilization(0, 0), 0);
        assertApproxEqAbs(m.getBorrowRate(55, 45), 3e25, 1e10); // U 45% -> 3%
        assertApproxEqAbs(m.getBorrowRate(10, 90), 6e25, 1e10); // kink
        assertApproxEqAbs(m.getBorrowRate(0, 100), 66e25, 1e10); // full
        assertApproxEqAbs(m.getBorrowRate(5, 95), 36e25, 1e10); // halfway up slope2
    }

    function test_constructorValidation() public {
        vm.expectRevert(LLErrors.InvalidParams.selector);
        new InterestRateModel(0, 1, 1, 0);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        new InterestRateModel(0, 1, 1, 1e27);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        new InterestRateModel(5e27, 5e27, 1e27, 5e26);
    }
}

contract AssetConfigTest is BaseTest {
    function test_validation() public {
        Types.RiskParams memory p = _stockParams(1, 0, 0);
        p.ltvBps = 7_100; // > lt
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        p = _stockParams(1, 0, 0);
        p.liqThresholdBps = 9_500; // 95% * 1.08 >= 100%
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        p = _stockParams(1, 0, 0);
        p.closedLtvBps = 6_500;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        p = _stockParams(1, 0, 0);
        p.reserveFactorBps = 6_000;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        p = _stockParams(1, 0, 0);
        p.liqProtocolFeeBps = 6_000;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        p = _stockParams(1, 0, 0);
        p.eModeCategory = 7;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        p = _stockParams(1, 0, 100);
        p.closedBorrowCap = 200;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
        vm.expectRevert(LLErrors.ReserveNotActive.selector);
        d.assetConfig.setRiskParams(address(0xbeef), _stockParams(1, 0, 0));
        p = _stockParams(1, 0, 0);
        p.liqBonusBps = 2_500;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setRiskParams(address(aapl), p);
    }

    function test_eModeAndIrm() public {
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.assetConfig.setEModeCategory(0, 1, 2, 3, "x");
        d.assetConfig.setEModeCategory(2, 8_000, 8_500, 300, "Index");
        assertEq(d.assetConfig.getEModeCategory(2).liqThresholdBps, 8_500);
        assertEq(d.assetConfig.getEModeCategory(2).label, "Index");

        InterestRateModel m = new InterestRateModel(0, 1e26, 1e27, 8e26);
        d.assetConfig.setInterestRateModel(address(usdg), address(m));
        assertEq(d.assetConfig.interestRateModel(address(usdg)), address(m));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.assetConfig.setInterestRateModel(address(usdg), address(0));
        vm.expectRevert(LLErrors.ReserveNotActive.selector);
        d.assetConfig.setInterestRateModel(address(0xbeef), address(m));
    }

    function test_listing_and_pool_once() public {
        vm.expectRevert(LLErrors.AlreadySet.selector);
        d.assetConfig.setPool(address(1));
        AssetConfig fresh = new AssetConfig(address(this));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        fresh.setPool(address(0));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new AssetConfig(address(0));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.assetConfig.listAsset(address(1), address(1), address(1), address(0), _stableParams(0, 0));
        vm.prank(alice);
        vm.expectRevert();
        d.assetConfig.setRiskParams(address(usdg), _stableParams(0, 0));
    }

    function test_disabledCollateral_zeroLtvKeepsThreshold() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 1_000e6);
        Types.RiskParams memory p = _stockParams(1, 0, 0);
        p.collateralEnabled = false;
        _setParams(address(aapl), p);
        Types.AccountData memory a = d.pool.getUserAccountData(bob);
        assertEq(a.borrowPowerUsd, 0);
        assertEq(a.weightedThresholdUsd, 1_400e18); // not instantly liquidatable
    }
}
