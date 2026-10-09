// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RobinhoodChain as RH} from "./RobinhoodChain.sol";
import {Pool} from "../src/core/Pool.sol";
import {OracleAdapter} from "../src/risk/OracleAdapter.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockAggregator} from "../test/mocks/MockAggregator.sol";

/// @title SeedFork
/// @notice LOCAL ANVIL FORK ONLY. Seeds demo positions so the frontend can be exercised end-to-end:
///         a liquidity provider, a healthy borrower, a short seller, and one borrower that becomes
///         liquidatable after an NVDA price shock (the Timelock is impersonated to point NVDA at a
///         demo feed). Token balances are written with anvil_setStorageAt. Never run against mainnet:
///         it refuses unless the RPC answers anvil_* methods.
///
/// Usage (after Deploy.s.sol on the fork):
///   DEPLOYMENT_NAME=4663-fork forge script script/SeedFork.s.sol --rpc-url http://127.0.0.1:8711 \
///     --unlocked --sender 0x1000000000000000000000000000000000000001 --broadcast --slow
contract SeedFork is Script {
    using stdStorage for StdStorage;

    address constant LP = 0x00000000000000000000000000000000000000A1;
    address constant DEV = 0x00000000000000000000000000000000000000A2; // NEXT_PUBLIC_DEV_MOCK_ACCOUNT
    address constant BOB = 0x00000000000000000000000000000000000000B0;
    address constant CAROL = 0x00000000000000000000000000000000000000C0;
    address constant DAVE = 0x00000000000000000000000000000000000000d0;
    address constant LIQ = 0x00000000000000000000000000000000000000E0;

    Pool pool;

    function run() external {
        require(block.chainid == RH.CHAIN_ID, "SeedFork: expected a fork of chain 4663");
        // Refuse to run anywhere that is not anvil.
        vm.rpc("anvil_nodeInfo", "[]");

        string memory name = vm.envOr("DEPLOYMENT_NAME", string("4663-fork"));
        string memory json = vm.readFile(string.concat("../deployments/", name, ".json"));
        pool = Pool(vm.parseJsonAddress(json, ".contracts.Pool"));
        OracleAdapter oracle = OracleAdapter(vm.parseJsonAddress(json, ".contracts.OracleAdapter"));
        address timelock = vm.parseJsonAddress(json, ".contracts.Timelock");

        vm.rpc("anvil_setBalance", string.concat('["', vm.toString(timelock), '","0x8AC7230489E80000"]'));
        if (vm.envOr("SHOCK_ONLY", false)) return _shock(oracle, timelock);

        address[6] memory users = [LP, DEV, BOB, CAROL, DAVE, LIQ];
        for (uint256 i; i < users.length; ++i) {
            vm.rpc("anvil_setBalance", string.concat('["', vm.toString(users[i]), '","0x8AC7230489E80000"]'));
        }
        _setBalance(RH.USDG, LP, 3_000_000e6);
        _setBalance(RH.AAPL, LP, 2_000e18);
        _setBalance(RH.NVDA, LP, 1_000e18);
        _setBalance(RH.TSLA, LP, 400e18);
        _setBalance(RH.MSFT, LP, 500e18);
        _setBalance(RH.USDG, DEV, 50_000e6);
        _setBalance(RH.AAPL, DEV, 50e18);
        _setBalance(RH.NVDA, DEV, 20e18);
        _setBalance(RH.AAPL, BOB, 100e18);
        _setBalance(RH.USDG, CAROL, 60_000e6);
        _setBalance(RH.NVDA, DAVE, 40e18);
        _setBalance(RH.USDG, LIQ, 100_000e6);

        // Liquidity provider fills every market used below.
        _supply(LP, RH.USDG, 2_000_000e6);
        _supply(LP, RH.AAPL, 2_000e18);
        _supply(LP, RH.NVDA, 1_000e18);
        _supply(LP, RH.TSLA, 400e18);
        _supply(LP, RH.MSFT, 500e18);

        // Bob: healthy AAPL-collateralized USDG loan at ~40% of borrow power.
        _supply(BOB, RH.AAPL, 100e18);
        _borrowShareOfPower(BOB, RH.USDG, 4_000);

        // Carol: shorts TSLA against USDG at ~50% of power.
        _supply(CAROL, RH.USDG, 60_000e6);
        _borrowShareOfPower(CAROL, RH.TSLA, 5_000);

        // Dave: NVDA collateral borrowed to ~97% of power, then an NVDA shock makes him liquidatable.
        _supply(DAVE, RH.NVDA, 40e18);
        _borrowShareOfPower(DAVE, RH.USDG, 9_700);

        _shock(oracle, timelock);
        console2.log("Bob health factor:", pool.getUserAccountData(BOB).healthFactor);
        console2.log("Seeded. Dev account (frontend):", DEV);
    }

    /// @dev Points NVDA at a demo feed 45% below the live price (impersonating the Timelock).
    function _shock(OracleAdapter oracle, address timelock) internal {
        (, int256 nvda,,,) = IAggregatorV3(RH.NVDA_FEED).latestRoundData();
        vm.startBroadcast(timelock); // impersonated on anvil (--auto-impersonate)
        MockAggregator demoFeed = new MockAggregator(8, nvda * 55 / 100);
        oracle.setFeed(
            RH.NVDA,
            OracleAdapter.FeedConfig(address(demoFeed), address(0), 25 hours, 4 days, 0, true, 0.01e18, 0)
        );
        vm.stopBroadcast();

        console2.log("NVDA demo price (8 dec):", uint256(nvda * 55 / 100));
        console2.log("Dave health factor (1e18 = 1.0):", pool.getUserAccountData(DAVE).healthFactor);
    }

    function _setBalance(address token, address who, uint256 amount) internal {
        uint256 slot = stdstore.target(token).sig(IERC20.balanceOf.selector).with_key(who).find();
        vm.rpc(
            "anvil_setStorageAt",
            string.concat('["', vm.toString(token), '","', vm.toString(bytes32(slot)), '","', vm.toString(bytes32(amount)), '"]')
        );
        vm.store(token, bytes32(slot), bytes32(amount)); // keep the local simulation in sync
    }

    function _supply(address who, address token, uint256 amount) internal {
        vm.startBroadcast(who);
        IERC20(token).approve(address(pool), type(uint256).max);
        pool.supply(token, amount, who);
        vm.stopBroadcast();
    }

    function _borrowShareOfPower(address who, address token, uint256 bps) internal {
        Types.AccountData memory a = pool.getUserAccountData(who);
        (, address o,,,,,,) = pool.modules();
        uint256 price = OracleAdapter(o).getPrice(token);
        uint256 usd = (a.borrowPowerUsd - a.debtUsd) * bps / 10_000;
        uint8 dec = token == RH.USDG ? 6 : 18;
        uint256 amount = usd * (10 ** dec) / price;
        vm.startBroadcast(who);
        pool.borrow(token, amount);
        vm.stopBroadcast();
    }
}
