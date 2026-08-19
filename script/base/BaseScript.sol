// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {Deployers} from "test/utils/Deployers.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script, Deployers {
    address immutable deployerAddress;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    // Only used on non-local chains; on chain 31337 (anvil) fresh mock tokens are deployed
    // and minted to the deployer instead, since these placeholders won't have code there.
    IERC20 internal constant token0 = IERC20(0x0165878A594ca255338adfa4d48449f69242Eb8F);
    IERC20 internal constant token1 = IERC20(0xa513E6E4b8f2a923D98304ec87F64353C4D5C853);
    /////////////////////////////////////

    // Set via the HOOK_ADDRESS env var once 00_DeployHook.s.sol has run and mined/deployed
    // the hook's address - it can't be a compile-time constant since CREATE2 mining decides
    // the address at deploy time.
    IHooks internal hookContract;

    // Not immutable: on chain 31337 these are only resolved once `ensureCurrencies()` runs
    // (see its doc comment for why that can't happen here in the constructor).
    Currency currency0;
    Currency currency1;

    constructor() {
        // Make sure artifacts are available, either deploy or configure.
        deployArtifacts();

        deployerAddress = getDeployer();

        if (block.chainid != 31337) {
            require(address(token0) != address(token1));
            (currency0, currency1) = token0 < token1
                ? (Currency.wrap(address(token0)), Currency.wrap(address(token1)))
                : (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
            vm.label(Currency.unwrap(currency0), "Currency0");
            vm.label(Currency.unwrap(currency1), "Currency1");
        }

        hookContract = IHooks(vm.envOr("HOOK_ADDRESS", address(0)));

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");

        vm.label(address(hookContract), "HookContract");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
        } else {
            revert("Unsupported etch on this network");
        }
    }

    // deployPoolManager/deployPositionManager/deployRouter (from Deployers) redeploy a fresh
    // instance on every call for chain 31337, via a plain CREATE2 keyed off this script
    // contract's own address - which differs between separate `forge script` invocations.
    // That means a later script's non-broadcast constructor-time call resolves to a
    // different, code-less address than whatever a prior script actually broadcast. These
    // overrides let a later script reuse the real deployment via env vars instead.
    function deployPoolManager() internal override {
        address existing = vm.envOr("POOL_MANAGER_ADDRESS", address(0));
        if (block.chainid == 31337 && existing != address(0)) {
            poolManager = IPoolManager(existing);
            return;
        }
        super.deployPoolManager();
    }

    function deployPositionManager() internal override {
        address existing = vm.envOr("POSITION_MANAGER_ADDRESS", address(0));
        if (block.chainid == 31337 && existing != address(0)) {
            positionManager = IPositionManager(existing);
            return;
        }
        super.deployPositionManager();
    }

    function deployRouter() internal override {
        address existing = vm.envOr("ROUTER_ADDRESS", address(0));
        if (block.chainid == 31337 && existing != address(0)) {
            swapRouter = IUniswapV4Router04(payable(existing));
            return;
        }
        super.deployRouter();
    }

    function getDeployer() internal returns (address) {
        address[] memory wallets = vm.getWallets();

        if (wallets.length > 0) {
            return wallets[0];
        } else {
            return msg.sender;
        }
    }

    /// @notice On local anvil, the hardcoded token0/token1 placeholders above don't have
    /// code, so fresh test tokens need to be deployed and minted to the deployer instead.
    ///
    /// This must be called from inside the calling script's own vm.startBroadcast()/
    /// stopBroadcast() block, not from this contract's constructor - a deployment made in
    /// the constructor only exists in Foundry's local simulation of the script and never
    /// actually lands on chain.
    ///
    /// Deploys tokens directly rather than via Deployers.deployCurrencyPair(): that helper
    /// mints to address(this) and is meant for tests, where address(this) is the test
    /// contract acting as the trader itself. In a script, address(this) is the ephemeral
    /// script contract, and Foundry's own safety check reverts on any use of address(this)
    /// in a script for exactly that reason - so this mints straight to deployerAddress
    /// instead, the address every broadcasted call in these scripts actually runs as.
    ///
    /// No-op on every other network, where currency0/currency1 are already resolved.
    ///
    /// If CURRENCY0/CURRENCY1 env vars are set, those are reused instead of deploying a new
    /// pair - each separate `forge script` invocation is its own process with no shared
    /// state, so without this a later script (e.g. 03_Swap.s.sol) would otherwise deploy a
    /// fresh pair and end up pointing at a pool that was never created.
    function ensureCurrencies() internal {
        if (block.chainid != 31337 || Currency.unwrap(currency0) != address(0)) return;

        address envCurrency0 = vm.envOr("CURRENCY0", address(0));
        address envCurrency1 = vm.envOr("CURRENCY1", address(0));
        if (envCurrency0 != address(0) && envCurrency1 != address(0)) {
            currency0 = Currency.wrap(envCurrency0);
            currency1 = Currency.wrap(envCurrency1);
            vm.label(envCurrency0, "Currency0");
            vm.label(envCurrency1, "Currency1");
            return;
        }

        MockERC20 tokenA = new MockERC20("Cadence Test Token A", "CTA", 18);
        MockERC20 tokenB = new MockERC20("Cadence Test Token B", "CTB", 18);
        tokenA.mint(deployerAddress, 10_000_000 ether);
        tokenB.mint(deployerAddress, 10_000_000 ether);

        (currency0, currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }
}
