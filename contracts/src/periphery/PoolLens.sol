// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {Types} from "../libraries/Types.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IAssetConfig} from "../interfaces/IAssetConfig.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IReceiptToken, IDebtToken} from "../interfaces/ITokens.sol";

interface IPoolModules {
    function modules()
        external
        view
        returns (address, address, address, address, address, address, address, uint16);
    function isMarketOpen() external view returns (bool);
}

/// @title PoolLens
/// @notice Stateless aggregation views for the frontend. Never used by core contracts.
contract PoolLens {
    using MathLib for uint256;

    struct Market {
        address asset;
        string symbol;
        uint8 decimals;
        address receiptToken;
        address debtToken;
        uint256 totalSupply;
        uint256 totalDebt;
        uint256 cash;
        uint256 utilizationRay;
        uint256 borrowRateRay;
        uint256 supplyRateRay;
        uint256 priceWad; // 0 if the oracle reverts (e.g. stale)
        bool priceOk;
        bool frozen;
        bool paused;
        Types.RiskParams params;
    }

    struct Position {
        address asset;
        uint256 supplied;
        uint256 borrowed;
        bool collateral;
    }

    IPool public immutable POOL;

    constructor(IPool pool) {
        POOL = pool;
    }

    // Only two of the eight module addresses are needed.
    // slither-disable-start unused-return
    function _modules() internal view returns (IAssetConfig cfg, IPriceOracle oracle) {
        (address c, address o,,,,,,) = IPoolModules(address(POOL)).modules();
        return (IAssetConfig(c), IPriceOracle(o));
    }
    // slither-disable-end unused-return

    function getMarkets() external view returns (Market[] memory markets, bool marketOpen) {
        address[] memory list = POOL.getReservesList();
        (IAssetConfig cfg, IPriceOracle oracle) = _modules();
        markets = new Market[](list.length);
        for (uint256 i; i < list.length; ++i) {
            markets[i] = _market(list[i], cfg, oracle);
        }
        marketOpen = IPoolModules(address(POOL)).isMarketOpen();
    }

    function _market(address asset, IAssetConfig cfg, IPriceOracle oracle) internal view returns (Market memory m) {
        Types.ReserveData memory r = POOL.getReserveData(asset);
        m.asset = asset;
        m.symbol = IERC20Metadata(asset).symbol();
        m.decimals = IERC20Metadata(asset).decimals();
        m.receiptToken = r.receiptToken;
        m.debtToken = r.debtToken;
        m.totalSupply = POOL.totalSupplyAssets(asset);
        m.totalDebt = POOL.totalDebt(asset);
        m.cash = r.cash;
        m.params = cfg.getRiskParams(asset);
        m.borrowRateRay = r.borrowRateRay;
        uint256 denom = r.cash + m.totalDebt;
        m.utilizationRay = denom == 0 ? 0 : m.totalDebt.mulDivDown(MathLib.RAY, denom);
        m.supplyRateRay = uint256(r.borrowRateRay).rayMulDown(m.utilizationRay).bpsMulDown(
            MathLib.BPS - m.params.reserveFactorBps
        );
        m.frozen = r.frozen;
        m.paused = r.paused;
        try oracle.getPrice(asset) returns (uint256 p) {
            m.priceWad = p;
            m.priceOk = true;
        } catch {}
    }

    function getUserPositions(address user)
        external
        view
        returns (Position[] memory positions, Types.AccountData memory account, uint8 eMode)
    {
        address[] memory list = POOL.getReservesList();
        uint256 cfgBits = POOL.getUserConfig(user);
        positions = new Position[](list.length);
        for (uint256 i; i < list.length; ++i) {
            Types.ReserveData memory r = POOL.getReserveData(list[i]);
            positions[i] = Position({
                asset: list[i],
                supplied: IReceiptToken(r.receiptToken).balanceOf(user).rayMulDown(POOL.getNormalizedIncome(list[i])),
                borrowed: IDebtToken(r.debtToken).scaledBalanceOf(user).rayMulUp(POOL.getNormalizedDebt(list[i])),
                collateral: (cfgBits >> (i * 2 + 1)) & 1 == 1
            });
        }
        try POOL.getUserAccountData(user) returns (Types.AccountData memory a) {
            account = a;
        } catch {}
        eMode = POOL.getUserEMode(user);
    }

    /// @notice Batch health factors for the liquidations page (caller supplies candidate accounts).
    function getHealthFactors(address[] calldata users) external view returns (Types.AccountData[] memory out) {
        out = new Types.AccountData[](users.length);
        for (uint256 i; i < users.length; ++i) {
            try POOL.getUserAccountData(users[i]) returns (Types.AccountData memory a) {
                out[i] = a;
            } catch {}
        }
    }
}
