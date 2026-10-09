// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployCore} from "./DeployCore.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @title RobinhoodDeployment
/// @notice Robinhood Chain mainnet listing set, launch caps and pre/post-flight checks. Shared by
///         script/Deploy.s.sol and test/fork so the fork tests run exactly the production code path.
abstract contract RobinhoodDeployment is DeployCore {
    struct Listing {
        address token;
        address feed;
        uint8 tier; // 0 index ETF, 1 large-cap tech (e-mode), 2 high volatility
    }

    uint256 internal constant STOCK_SUPPLY_CAP_USD = 2_000_000;
    uint256 internal constant STOCK_BORROW_CAP_USD = 500_000;
    uint128 internal constant USDG_SUPPLY_CAP = 10_000_000e6;
    uint128 internal constant USDG_BORROW_CAP = 8_000_000e6;

    function listings() public pure returns (Listing[] memory l) {
        l = new Listing[](9);
        l[0] = Listing(RH.AAPL, RH.AAPL_FEED, 1);
        l[1] = Listing(RH.MSFT, RH.MSFT_FEED, 1);
        l[2] = Listing(RH.NVDA, RH.NVDA_FEED, 1);
        l[3] = Listing(RH.GOOGL, RH.GOOGL_FEED, 1);
        l[4] = Listing(RH.META, RH.META_FEED, 1);
        l[5] = Listing(RH.AMZN, RH.AMZN_FEED, 1);
        l[6] = Listing(RH.TSLA, RH.TSLA_FEED, 2);
        l[7] = Listing(RH.SPY, RH.SPY_FEED, 0);
        l[8] = Listing(RH.QQQ, RH.QQQ_FEED, 0);
    }

    /// @notice Deploys, wires, lists every market and hands admin to the Timelock.
    function _deployRobinhood(Config memory c) internal returns (Deployment memory d) {
        Listing[] memory l = listings();
        d = _deployCore(c);
        _listAsset(d, AssetSpec(RH.USDG, RH.USDG_USD_FEED, false, _stableParams(USDG_SUPPLY_CAP, USDG_BORROW_CAP)));
        for (uint256 i; i < l.length; ++i) {
            (uint128 supplyCap, uint128 borrowCap) = _caps(l[i].feed);
            _listAsset(d, AssetSpec(l[i].token, l[i].feed, true, _stockParams(l[i].tier, supplyCap, borrowCap)));
        }
        _handover(d, c);
    }

    /// @dev Never deploy against addresses that are not live: code, metadata and fresh-enough prices.
    function _preflight() internal view {
        require(block.chainid == RH.CHAIN_ID, "Deploy: not Robinhood Chain (4663) or a fork of it");
        Listing[] memory l = listings();
        _checkAsset(RH.USDG, RH.USDG_USD_FEED, 6);
        for (uint256 i; i < l.length; ++i) {
            _checkAsset(l[i].token, l[i].feed, 18);
        }
    }

    function _checkAsset(address token, address feed, uint8 expectedDecimals) internal view {
        require(token.code.length > 0, "preflight: no code at token");
        require(feed.code.length > 0, "preflight: no code at feed");
        require(IERC20Metadata(token).decimals() == expectedDecimals, "preflight: unexpected token decimals");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "preflight: feed answer <= 0");
        require(block.timestamp - updatedAt < 7 days, "preflight: feed older than 7 days");
    }

    /// @dev Converts USD caps into whole-token caps at the current oracle price.
    function _caps(address feed) internal view returns (uint128 supplyCap, uint128 borrowCap) {
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        uint256 dec = IAggregatorV3(feed).decimals();
        uint256 price = uint256(answer);
        supplyCap = uint128((STOCK_SUPPLY_CAP_USD * 10 ** dec / price) * 1e18);
        borrowCap = uint128((STOCK_BORROW_CAP_USD * 10 ** dec / price) * 1e18);
    }

    function _postflight(Deployment memory d, address deployer) internal view {
        require(!d.pool.hasRole(0x00, deployer), "postflight: deployer still pool admin");
        require(d.pool.hasRole(0x00, address(d.timelock)), "postflight: timelock not pool admin");
        require(!d.assetConfig.hasRole(0x00, deployer), "postflight: deployer still config admin");
        require(d.hooks.owner() == address(d.timelock), "postflight: hooks not owned by timelock");
        require(!d.hooks.isActive(), "postflight: project token must not be set at deploy");
        require(!d.compliance.enabled(), "postflight: compliance must be off by default");
        require(d.pool.getReservesList().length == 10, "postflight: listing count");
        require(d.timelock.getMinDelay() >= 48 hours, "postflight: timelock delay");
    }
}
