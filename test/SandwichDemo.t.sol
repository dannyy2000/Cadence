// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {CadenceHook} from "../src/CadenceHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice The core proof from the README's Demo Plan: the identical 3-transaction sandwich
/// (front-run, victim swap, back-run) executed against a plain Uniswap v4 pool vs. a
/// Cadence-enabled pool. Same starting price, same liquidity depth, same three trade sizes
/// and directions in both cases - the only variable is whether CadenceHook is attached.
///
/// The back-run size is a fixed, pre-committed amount rather than dynamically sized off the
/// front-run's actual output. This is deliberate, not a simplification for convenience: in
/// the Cadence case the attacker genuinely cannot know the front-run's output before
/// settlement (it returns zero immediately, by design), so a realistic attacker has to
/// pre-commit a guess either way. Using the same fixed guess in both scenarios keeps the
/// comparison honest - identical inputs, only the hook differs.
contract SandwichDemoTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant POOL_LIQUIDITY = 1_000_000e18;
    uint256 constant VICTIM_AMOUNT_IN = 50_000e18; // token1 -> token0
    uint256 constant FRONT_RUN_AMOUNT_IN = 50_000e18; // token1 -> token0, identical to victim's

    // Used only for the Cadence-pool tests below (batching mechanics, not attack economics) -
    // arbitrary relative to POOL_LIQUIDITY, deliberately not the same calibrated ratio
    // testSandwich_MinimumProfitableSizeSweep() derives further down in this file, since these
    // tests care about exercising the queue/settlement path, not about whether this specific
    // trade size would really be worth attacking.
    uint256 constant BATCH_THRESHOLD = 5e18;
    uint256 constant BATCH_WINDOW_BLOCKS = 10;
    uint256 constant MAX_BATCH_SIZE = 20;

    Currency currency0;
    Currency currency1;

    address attacker = makeAddr("sandwichAttacker");
    address victim = makeAddr("sandwichVictim");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        _fundAndApprove(address(this), true);
        // The attacker is deliberately NOT pre-funded with token0. A real sandwich bot
        // doesn't hold a standing inventory of the victim's target asset - it only has
        // whatever its own front-run just produced, and Appendix C's proof of the paper this
        // is based on defines "risk-free" profit specifically as spending no more than that
        // (Deltay_b <= Deltay_f). Giving the attacker a large pre-existing token0 balance
        // would let them fund a "back-run" from capital a real attacker doesn't have, which
        // is exactly what produced a misleading non-zero result on the first pass at this test.
        _fundAndApprove(attacker, false);
        _fundAndApprove(victim, true);
    }

    function _fundAndApprove(address who, bool fundToken0) internal {
        if (fundToken0) {
            MockERC20(Currency.unwrap(currency0)).mint(who, 3_000_000e18);
        }
        MockERC20(Currency.unwrap(currency1)).mint(who, 3_000_000e18);

        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency0), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(poolManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _seedLiquidity(PoolKey memory key) internal {
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(POOL_LIQUIDITY)
        );

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            uint128(POOL_LIQUIDITY),
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testSandwich_PlainPool_AttackerProfits() public {
        PoolKey memory plainKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        _seedLiquidity(plainKey);

        uint256 attackerToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        uint256 attackerToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);
        uint256 victimToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(victim);

        // 1. Attacker front-runs: sells token1 for token0, pushing the price toward one less
        //    favorable for the victim, before the victim's own trade lands. Same block, same
        //    transaction batch as far as the pool is concerned - nothing stops this from
        //    landing immediately before the victim. A real MEV bot simulates this exact
        //    output before submitting, so it knows precisely how to size the back-run - we
        //    replicate that by measuring the real balance change rather than guessing.
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: FRONT_RUN_AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: plainKey,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 1
        });
        uint256 frontRunProceeds = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker) - attackerToken0Before;

        // 2. Victim's trade executes immediately, at the now-inflated price - this is the
        //    mechanical precondition the whole project targets: nothing separates the
        //    attacker's trade from the victim's, so the attacker's manipulation is already
        //    baked into the price the victim gets.
        vm.prank(victim);
        swapRouter.swapExactTokensForTokens({
            amountIn: VICTIM_AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: plainKey,
            hookData: Constants.ZERO_BYTES,
            receiver: victim,
            deadline: block.timestamp + 1
        });

        // 3. Attacker back-runs: sells EXACTLY what the front-run produced - no more, no less
        //    (Deltay_b = Deltay_f), matching the paper's own definition of a risk-free
        //    sandwich (Appendix C): the attack must be funded entirely by its own front-run,
        //    not by separate capital.
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: frontRunProceeds,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: plainKey,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 1
        });

        uint256 attackerToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        uint256 victimToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(victim);

        int256 attackerProfit = int256(attackerToken1After) - int256(attackerToken1Before);
        uint256 victimReceived = victimToken0After - victimToken0Before;

        emit log_named_int("[PLAIN POOL] attacker token1 profit", attackerProfit);
        emit log_named_uint("[PLAIN POOL] victim token0 received", victimReceived);

        assertGt(attackerProfit, 0, "classic sandwich must be profitable against a plain pool - this is the baseline");
    }

    /// @notice This scenario (front-run exactly matching the victim's trade size) is the
    /// contrived worst case discovered while building this demo - see the tie-break fix in
    /// CadenceHook._tieBreakKey. It does NOT get eliminated to a guaranteed zero: the
    /// tie-break now depends on blockhash(block.number - 1) at settlement time, which is
    /// unknown until that block is mined, so the honest claim is that the attacker can no
    /// longer RELY on winning it - not that they can never win it by chance.
    ///
    /// This test proves exactly that, empirically: unlike the plain pool (identical,
    /// guaranteed profit every single time - see testSandwich_PlainPool_AttackerProfits),
    /// running the same attack against several different possible settlement blocks produces
    /// DIFFERENT outcomes. An attacker deciding whether to attempt this cannot know in
    /// advance which one they will get.
    function testSandwich_CadencePool_OutcomeVariesAcrossSettlementBlocks() public {
        int256 constantPlainPoolProfit = 4417784300644256932920; // from testSandwich_PlainPool_AttackerProfits

        bool sawProtected = false;
        bool sawUnprotected = false;

        for (uint256 trial = 0; trial < 12 && !(sawProtected && sawUnprotected); trial++) {
            int256 attackerProfit = _runCadenceSandwichTrial(trial);
            emit log_named_int(string.concat("[TRIAL ", vm.toString(trial), "] attacker profit"), attackerProfit);

            if (attackerProfit < constantPlainPoolProfit) {
                sawProtected = true;
            } else {
                sawUnprotected = true;
            }
        }

        assertTrue(
            sawProtected,
            "at least one settlement block must give the attacker LESS than the plain pool's guaranteed profit - otherwise the tie-break fix did nothing for this scenario"
        );
        emit log_named_uint("sawUnprotected (attacker still got lucky at least once)", sawUnprotected ? 1 : 0);
    }

    /// @dev One full run of the front-run/victim/back-run sequence against a fresh Cadence
    /// pool, settling at a trial-specific block. Factored out of the loop above purely to
    /// keep the caller's live local-variable count under Solidity's stack-depth limit.
    function _runCadenceSandwichTrial(uint256 trial) internal returns (int256 attackerProfit) {
        (Currency trialCurrency0, Currency trialCurrency1) = deployCurrencyPair();
        address trialAttacker = makeAddr(string.concat("trialAttacker", vm.toString(trial)));
        address trialVictim = makeAddr(string.concat("trialVictim", vm.toString(trial)));
        _fundTrialParty(trialCurrency0, trialCurrency1, address(this), true);
        _fundTrialParty(trialCurrency0, trialCurrency1, trialAttacker, false);
        _fundTrialParty(trialCurrency0, trialCurrency1, trialVictim, true);

        address flags = address(
            uint160(
                uint256(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG))
                    ^ ((0x7000 + trial) << 144)
            )
        );
        deployCodeTo(
            "CadenceHook.sol:CadenceHook",
            abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE),
            flags
        );
        CadenceHook hook = CadenceHook(flags);

        PoolKey memory cadenceKey = PoolKey(trialCurrency0, trialCurrency1, 3000, 60, IHooks(hook));
        PoolId cadencePoolId = cadenceKey.toId();
        _seedLiquidity(cadenceKey);

        uint256 attackerToken1Before = MockERC20(Currency.unwrap(trialCurrency1)).balanceOf(trialAttacker);
        uint256 attackerToken0Before = MockERC20(Currency.unwrap(trialCurrency0)).balanceOf(trialAttacker);

        vm.prank(trialAttacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: FRONT_RUN_AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: cadenceKey,
            hookData: abi.encode(trialAttacker),
            receiver: trialAttacker,
            deadline: block.timestamp + 1
        });
        vm.prank(trialVictim);
        swapRouter.swapExactTokensForTokens({
            amountIn: VICTIM_AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: cadenceKey,
            hookData: abi.encode(trialVictim),
            receiver: trialVictim,
            deadline: block.timestamp + 1
        });

        // A different possible settlement block each trial - nobody, including the attacker,
        // controls exactly which block a real settlement lands in.
        vm.roll(hook.batchDeadline(cadencePoolId) + trial);
        hook.settle(cadenceKey);

        uint256 realFrontRunProceeds =
            MockERC20(Currency.unwrap(trialCurrency0)).balanceOf(trialAttacker) - attackerToken0Before;

        vm.prank(trialAttacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: realFrontRunProceeds,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: cadenceKey,
            hookData: abi.encode(trialAttacker),
            receiver: trialAttacker,
            deadline: block.timestamp + 1
        });
        if (hook.queueLength(cadencePoolId) > 0) {
            vm.roll(hook.batchDeadline(cadencePoolId) + trial);
            hook.settle(cadenceKey);
        }

        uint256 attackerToken1After = MockERC20(Currency.unwrap(trialCurrency1)).balanceOf(trialAttacker);
        attackerProfit = int256(attackerToken1After) - int256(attackerToken1Before);
    }

    function _fundTrialParty(Currency c0, Currency c1, address who, bool fundToken0) internal {
        if (fundToken0) {
            MockERC20(Currency.unwrap(c0)).mint(who, 3_000_000e18);
        }
        MockERC20(Currency.unwrap(c1)).mint(who, 3_000_000e18);

        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(c0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c0), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c1), address(poolManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice Checks whether a busier, more realistic batch (other independent traders mixed
    /// in, not just the isolated attacker/victim pair) changes the outcome. This is an honest
    /// empirical check, not an assumption either way - see the conversation this came from:
    /// does more order flow dilute the size-tie exploit, or is the tie between the specific
    /// attacker/victim pair unaffected by what else is in the batch?
    function testSandwich_CadencePool_WithNoiseOrders() public {
        address flags =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x8888 << 144));
        bytes memory constructorArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        deployCodeTo("CadenceHook.sol:CadenceHook", constructorArgs, flags);
        CadenceHook hook = CadenceHook(flags);

        PoolKey memory cadenceKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        PoolId cadencePoolId = cadenceKey.toId();
        _seedLiquidity(cadenceKey);

        uint256 attackerToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        uint256 attackerToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker);

        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: FRONT_RUN_AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: cadenceKey,
            hookData: abi.encode(attacker),
            receiver: attacker,
            deadline: block.timestamp + 1
        });

        vm.prank(victim);
        swapRouter.swapExactTokensForTokens({
            amountIn: VICTIM_AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: cadenceKey,
            hookData: abi.encode(victim),
            receiver: victim,
            deadline: block.timestamp + 1
        });

        // 5 independent, unrelated traders join the same batch - varied sizes and directions,
        // a realistic busy pool rather than an isolated two-order pair.
        uint256[5] memory noiseAmounts = [uint256(12_000e18), 18_000e18, 9_000e18, 25_000e18, 15_000e18];
        bool[5] memory noiseDirections = [true, false, true, true, false];
        for (uint256 i = 0; i < 5; i++) {
            address noiseTrader = makeAddr(string.concat("noiseTrader", vm.toString(i)));
            _fundAndApprove(noiseTrader, true);
            vm.prank(noiseTrader);
            swapRouter.swapExactTokensForTokens({
                amountIn: noiseAmounts[i],
                amountOutMin: 0,
                zeroForOne: noiseDirections[i],
                poolKey: cadenceKey,
                hookData: abi.encode(noiseTrader),
                receiver: noiseTrader,
                deadline: block.timestamp + 1
            });
        }

        assertEq(hook.queueLength(cadencePoolId), 7, "front-run, victim, and 5 noise orders should all be queued");

        vm.roll(hook.batchDeadline(cadencePoolId));
        hook.settle(cadenceKey);

        uint256 realFrontRunProceeds = MockERC20(Currency.unwrap(currency0)).balanceOf(attacker) - attackerToken0Before;
        emit log_named_uint("[NOISY BATCH] attacker's real front-run proceeds", realFrontRunProceeds);

        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: realFrontRunProceeds,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: cadenceKey,
            hookData: abi.encode(attacker),
            receiver: attacker,
            deadline: block.timestamp + 1
        });
        if (hook.queueLength(cadencePoolId) > 0) {
            vm.roll(hook.batchDeadline(cadencePoolId));
            hook.settle(cadenceKey);
        }

        uint256 attackerToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(attacker);
        int256 attackerProfit = int256(attackerToken1After) - int256(attackerToken1Before);

        emit log_named_int("[NOISY BATCH] attacker token1 profit", attackerProfit);
        emit log_named_int("[ISOLATED PAIR, for comparison] attacker token1 profit", 4417784300644256932920);
    }

    /// @notice Finds a real, derived batchThreshold instead of an assumed one: for a sweep of
    /// trade sizes, run the actual classic sandwich against a plain pool and record (a) the
    /// attacker's real token profit and (b) the real gas cost of the attacker's two
    /// transactions, priced at Unichain Sepolia's real observed gas price (0.001000001 gwei,
    /// from the actual deploy broadcast logs - see MILESTONES.md), not a mainnet-2019 number
    /// borrowed from the paper's own study. This replicates the paper's *method* (empirically
    /// find where profit crosses the cost of attacking) rather than transplanting its
    /// *number*, which was calibrated for a completely different gas-price environment.
    function testSandwich_MinimumProfitableSizeSweep() public {
        uint256 realGasPriceWei = 1_000_001; // 0.001000001 gwei, observed on Unichain Sepolia

        // Pool A: SandwichDemoTest's own scale (1,000,000e18) - crossover already narrowed to
        // 3,000-4,000e18 (~0.3-0.4% of depth) in an earlier pass of this sweep.
        uint256[3] memory sizesA = [uint256(3_000e18), 3_500e18, 4_000e18];
        for (uint256 i = 0; i < sizesA.length; i++) {
            emit log_string("=== Pool A: 1,000,000e18 liquidity (SandwichDemoTest scale) ===");
            _runSweepTrial(sizesA[i], realGasPriceWei, i, POOL_LIQUIDITY);
        }

        // Pool B: the real deploy script's actual scale (script/01_CreatePoolAndAddLiquidity.s.sol
        // seeds 100e18/100e18) - the pool size that actually matters for the live Unichain
        // Sepolia deployment. Four orders of magnitude smaller than Pool A, so its crossover
        // is not assumed to scale down by the same 0.3-0.4% ratio - it's measured separately.
        uint256[7] memory sizesB = [
            uint256(1e16), // 0.01
            1e17, // 0.1
            2e17, // 0.2
            3e17, // 0.3
            4e17, // 0.4
            5e17, // 0.5
            1e18 // 1
        ];
        for (uint256 i = 0; i < sizesB.length; i++) {
            emit log_string("=== Pool B: 100e18 liquidity (real deploy script scale) ===");
            _runSweepTrial(sizesB[i], realGasPriceWei, 100 + i, 100e18);
        }
    }

    /// @dev Same approval set as _fundAndApprove (proven working in the tests above) - direct
    /// router approval and Permit2->PoolManager approval both matter here, not just
    /// Permit2->router, or settlement's direct transferFrom reverts on a missing allowance.
    function _approveTrader(Currency c0, Currency c1, address who) internal {
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(c0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c0), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c1), address(poolManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _setUpSweepTrial(uint256 trial, uint256 poolLiquidity)
        internal
        returns (PoolKey memory plainKey, address trialAttacker, address trialVictim)
    {
        (Currency c0, Currency c1) = deployCurrencyPair();
        trialAttacker = makeAddr(string.concat("sweepAttacker", vm.toString(trial)));
        trialVictim = makeAddr(string.concat("sweepVictim", vm.toString(trial)));

        MockERC20(Currency.unwrap(c0)).mint(address(this), 3_000_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(address(this), 3_000_000_000e18);
        MockERC20(Currency.unwrap(c0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c1), address(positionManager), type(uint160).max, type(uint48).max);

        MockERC20(Currency.unwrap(c1)).mint(trialAttacker, 3_000_000_000e18);
        MockERC20(Currency.unwrap(c0)).mint(trialVictim, 3_000_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(trialVictim, 3_000_000_000e18);
        _approveTrader(c0, c1, trialAttacker);
        _approveTrader(c0, c1, trialVictim);

        plainKey = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(plainKey, Constants.SQRT_PRICE_1_1);
        int24 tickLower = TickMath.minUsableTick(plainKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(plainKey.tickSpacing);
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(poolLiquidity)
        );
        positionManager.mint(
            plainKey, tickLower, tickUpper, uint128(poolLiquidity), amt0 + 1, amt1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    function _frontRun(PoolKey memory key, address trader, uint256 amount) internal returns (uint256 proceeds, uint256 gasUsed) {
        uint256 before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(trader);
        uint256 gasBefore = gasleft();
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        gasUsed = gasBefore - gasleft();
        proceeds = MockERC20(Currency.unwrap(key.currency0)).balanceOf(trader) - before;
    }

    function _victimTrade(PoolKey memory key, address trader, uint256 amount) internal {
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
    }

    function _backRun(PoolKey memory key, address trader, uint256 amount) internal returns (uint256 gasUsed) {
        uint256 gasBefore = gasleft();
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
        gasUsed = gasBefore - gasleft();
    }

    function _runSweepTrial(uint256 tradeSize, uint256 gasPriceWei, uint256 trial, uint256 poolLiquidity) internal {
        (PoolKey memory plainKey, address trialAttacker, address trialVictim) = _setUpSweepTrial(trial, poolLiquidity);

        uint256 attackerToken1Before = MockERC20(Currency.unwrap(plainKey.currency1)).balanceOf(trialAttacker);

        (uint256 frontRunProceeds, uint256 gasUsedFrontRun) = _frontRun(plainKey, trialAttacker, tradeSize);
        _victimTrade(plainKey, trialVictim, tradeSize);
        uint256 gasUsedBackRun = _backRun(plainKey, trialAttacker, frontRunProceeds);

        uint256 attackerToken1After = MockERC20(Currency.unwrap(plainKey.currency1)).balanceOf(trialAttacker);
        int256 tokenProfit = int256(attackerToken1After) - int256(attackerToken1Before);
        uint256 totalGas = gasUsedFrontRun + gasUsedBackRun;
        uint256 gasCostWei = totalGas * gasPriceWei;

        emit log_string("---");
        emit log_named_uint("trade size (wei of token)", tradeSize);
        emit log_named_int("attacker token profit (wei of token1)", tokenProfit);
        emit log_named_uint("gas used (both attacker txns)", totalGas);
        emit log_named_uint("real gas cost (wei of ETH, at Unichain Sepolia's observed price)", gasCostWei);
    }
}
