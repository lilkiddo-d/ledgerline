// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RobinhoodDeployment} from "./RobinhoodDeployment.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";
import {Types} from "../src/libraries/Types.sol";

/// @title Deploy
/// @notice One-shot deployment of Ledgerline to Robinhood Chain mainnet (or an anvil fork of it):
///         deploys and wires every contract, lists USDG + nine stock tokens, hands every admin role to
///         the 48h Timelock, and writes deployments/<name>.json plus app/src/generated/deployment.json.
///
///         Signer-agnostic: it never touches a private key. Production runs sign with the Foundry
///         keystore account `ledgerline-deployer` (`--account ledgerline-deployer`), see DEPLOY.md.
///
/// Optional env:
///   LEDGERLINE_GOVERNANCE  Timelock proposer/executor (multisig strongly recommended). Default: deployer.
///   LEDGERLINE_GUARDIAN    Instant pause/freeze role. Default: governance.
///   LEDGERLINE_TREASURY    Protocol revenue recipient. Default: governance.
///   LEDGERLINE_KEEPER      FeeCollector swap keeper. Default: governance.
///   DEPLOYMENT_NAME        Output file name. Default: chain id ("4663").
contract Deploy is Script, RobinhoodDeployment {
    uint256 internal startBlock;

    function run() external returns (Deployment memory d) {
        _preflight();
        // On Arbitrum-based chains block.number is the L1 block; record the L2 head for log scanning.
        startBlock = vm.parseUint(vm.toString(vm.rpc("eth_blockNumber", "[]")));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Config memory c = _config(deployer);
        console2.log("deployer  ", deployer);
        console2.log("governance", c.governance);
        d = _deployRobinhood(c);
        vm.stopBroadcast();

        _postflight(d, deployer);
        _write(d, c, listings());
    }

    function _config(address deployer) internal view returns (Config memory c) {
        address gov = vm.envOr("LEDGERLINE_GOVERNANCE", deployer);
        c = Config({
            deployer: deployer,
            governance: gov,
            guardian: vm.envOr("LEDGERLINE_GUARDIAN", gov),
            treasury: vm.envOr("LEDGERLINE_TREASURY", gov),
            keeper: vm.envOr("LEDGERLINE_KEEPER", gov),
            stablecoin: RH.USDG,
            timelockDelay: 48 hours
        });
    }

    // ------------------------------------------------------------------
    // Output
    // ------------------------------------------------------------------

    function _write(Deployment memory d, Config memory c, Listing[] memory l) internal {
        if (vm.isContext(VmSafe.ForgeContext.Test) || vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        string memory json = _json(d, c, l);
        string memory name = vm.envOr("DEPLOYMENT_NAME", vm.toString(block.chainid));
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            vm.writeFile(string.concat("../deployments/", name, ".dryrun.json"), json);
            console2.log("Dry run: wrote deployments/%s.dryrun.json (frontend config untouched)", name);
            return;
        }
        vm.writeFile(string.concat("../deployments/", name, ".json"), json);
        vm.writeFile("../app/src/generated/deployment.json", json);
        console2.log("Wrote deployments/%s.json and app/src/generated/deployment.json", name);
    }

    function _kv(string memory k, address v) internal pure returns (string memory) {
        return string.concat('"', k, '":"', vm.toString(v), '"');
    }

    function _json(Deployment memory d, Config memory c, Listing[] memory l) internal view returns (string memory) {
        string memory s = string.concat(
            '{"name":"Ledgerline","deployment":"',
            vm.envOr("DEPLOYMENT_NAME", vm.toString(block.chainid)),
            '","chainId":',
            vm.toString(block.chainid),
            ',"deployedAtBlock":',
            vm.toString(startBlock),
            ',"timestamp":',
            vm.toString(block.timestamp),
            ',"contracts":{',
            _kv("Pool", address(d.pool)),
            ",",
            _kv("AssetConfig", address(d.assetConfig)),
            ",",
            _kv("LiquidationLogic", address(d.liquidationLogic)),
            ",",
            _kv("FlashLoan", address(d.flashLoanModule)),
            ","
        );
        s = string.concat(
            s,
            _kv("MarketClock", address(d.clock)),
            ",",
            _kv("OracleAdapter", address(d.oracle)),
            ",",
            _kv("ComplianceRegistry", address(d.compliance)),
            ",",
            _kv("Reserve", address(d.reserve)),
            ",",
            _kv("FeeCollector", address(d.feeCollector)),
            ",",
            _kv("ProjectTokenHooks", address(d.hooks)),
            ","
        );
        s = string.concat(
            s,
            _kv("Timelock", address(d.timelock)),
            ",",
            _kv("PoolLens", address(d.lens)),
            ",",
            _kv("StableInterestRateModel", address(d.stableIrm)),
            ",",
            _kv("StockInterestRateModel", address(d.stockIrm)),
            "},",
            '"roles":{',
            _kv("governance", c.governance),
            ",",
            _kv("guardian", c.guardian),
            ",",
            _kv("treasury", c.treasury),
            ",",
            _kv("keeper", c.keeper),
            "},"
        );
        s = string.concat(s, '"stablecoin":"', vm.toString(RH.USDG), '","assets":[', _assetJson(d, RH.USDG, RH.USDG_USD_FEED));
        for (uint256 i; i < l.length; ++i) {
            s = string.concat(s, ",", _assetJson(d, l[i].token, l[i].feed));
        }
        return string.concat(s, "]}");
    }

    function _assetJson(Deployment memory d, address asset, address feed) internal view returns (string memory) {
        Types.ReserveData memory r = d.pool.getReserveData(asset);
        Types.RiskParams memory p = d.assetConfig.getRiskParams(asset);
        return string.concat(
            '{"symbol":"',
            IERC20Metadata(asset).symbol(),
            '","decimals":',
            vm.toString(uint256(IERC20Metadata(asset).decimals())),
            ",",
            _kv("address", asset),
            ",",
            _kv("receiptToken", r.receiptToken),
            ",",
            _kv("debtToken", r.debtToken),
            ",",
            _kv("feed", feed),
            ',"isStock":',
            p.isStock ? "true" : "false",
            ',"eModeCategory":',
            vm.toString(uint256(p.eModeCategory)),
            "}"
        );
    }
}
