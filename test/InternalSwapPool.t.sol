// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {InternalSwapPool} from "../src/InternalSwapPool.sol";

contract TestInternalSwapPool is Test, Deployers {
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    InternalSwapPool hook;

    function setUp() public {
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract and mint a bunch to ourselves
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));
        token.mint(address(this), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags ^ (0x4444 << 144));
        deployCodeTo("InternalSwapPool.sol", abi.encode(manager), hookAddress);
        hook = InternalSwapPool(payable(hookAddress));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize an ETH / TOKEN pool
        (key,) = initPool(ethCurrency, tokenCurrency, hook, 3000, SQRT_PRICE_1_1);

        // Add enough liquidity that our swaps stay well within range (~26 ETH / ~26 TOKEN)
        modifyLiquidityRouter.modifyLiquidity{value: 30 ether}(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_exactInput_zeroForOne_takesOnePercentFeeInToken1() public {
        BalanceDelta delta = _swap(true, -1 ether);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        uint256 received = uint256(int256(delta.amount1()));

        // User spent exactly their input and the 1% fee was taken from the TOKEN output
        assertEq(delta.amount0(), -1 ether);
        assertGt(fees.amount1, 0);
        assertEq(fees.amount1, (received + fees.amount1) / 100);
        assertEq(fees.amount0, 0);

        // Recorded fees are backed by the hook's balances
        assertEq(token.balanceOf(address(hook)), fees.amount1);
        assertEq(address(hook).balance, 0);
    }

    function test_exactOutput_zeroForOne_takesOnePercentFeeInETH() public {
        BalanceDelta delta = _swap(true, 0.001 ether);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        uint256 paid = uint256(int256(-delta.amount0()));

        // User received exactly their output and the 1% fee was added to the ETH input
        assertEq(delta.amount1(), 0.001 ether);
        assertGt(fees.amount0, 0);
        assertEq(fees.amount0, (paid - fees.amount0) / 100);
        assertEq(fees.amount1, 0);

        // The ETH fee is below the donation threshold, so the hook still holds it
        assertLt(fees.amount0, hook.DONATE_THRESHOLD_MIN());
        assertEq(address(hook).balance, fees.amount0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_exactInput_oneForZero_takesFeeInETH() public {
        BalanceDelta delta = _swap(false, -0.001 ether);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);

        // Selling TOKEN for ETH takes the fee from the ETH output, so it is recorded as amount0
        assertEq(delta.amount1(), -0.001 ether);
        assertGt(fees.amount0, 0);
        assertEq(fees.amount1, 0);
        assertEq(address(hook).balance, fees.amount0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_internalSwap_fullFill_exactInput() public {
        // Accrue TOKEN fees in the hook
        _swap(true, -1 ether);
        assertGt(hook.poolFees(key).amount1, 0);

        // A larger ETH -> TOKEN swap consumes all of the TOKEN fees before hitting the pool
        BalanceDelta delta = _swap(true, -0.1 ether);
        assertEq(delta.amount0(), -0.1 ether);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);

        // The ETH received for the TOKEN fees exceeded the threshold and was donated to LPs
        assertEq(fees.amount0, 0);
        assertEq(address(hook).balance, 0);

        // The only TOKEN fees left come from the part of this swap that went through the pool
        assertGt(fees.amount1, 0);
        assertEq(token.balanceOf(address(hook)), fees.amount1);
    }

    function test_internalSwap_partialFill_exactInput() public {
        // Accrue TOKEN fees in the hook
        _swap(true, -1 ether);
        uint256 tokenFeesBefore = hook.poolFees(key).amount1;

        // A small ETH -> TOKEN swap can only buy part of the TOKEN fees
        BalanceDelta delta = _swap(true, -0.001 ether);
        uint256 received = uint256(int256(delta.amount1()));

        // The whole swap was filled by the hook, without any pool fee being charged
        assertEq(delta.amount0(), -0.001 ether);
        assertGt(received, 0);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        assertEq(fees.amount1, tokenFeesBefore - received);
        assertEq(token.balanceOf(address(hook)), fees.amount1);

        // The ETH received reached the threshold and was donated to LPs
        assertEq(fees.amount0, 0);
        assertEq(address(hook).balance, 0);
    }

    function test_internalSwap_exactOutput() public {
        // Accrue TOKEN fees in the hook
        _swap(true, -1 ether);
        uint256 tokenFeesBefore = hook.poolFees(key).amount1;

        // Ask for less TOKEN than the hook holds so that it fills the whole swap
        uint256 amountOut = tokenFeesBefore / 2;
        BalanceDelta delta = _swap(true, int256(amountOut));

        assertEq(uint256(int256(delta.amount1())), amountOut);
        assertLt(delta.amount0(), 0);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        assertEq(fees.amount1, tokenFeesBefore - amountOut);
        assertEq(token.balanceOf(address(hook)), fees.amount1);

        // The ETH received reached the threshold and was donated to LPs
        assertEq(fees.amount0, 0);
        assertEq(address(hook).balance, 0);
    }

    function test_oneForZero_doesNotUseInternalPool() public {
        // Accrue TOKEN fees in the hook
        _swap(true, -1 ether);
        uint256 tokenFeesBefore = hook.poolFees(key).amount1;

        // Selling TOKEN for ETH must not touch the TOKEN fees
        _swap(false, -0.001 ether);

        assertEq(hook.poolFees(key).amount1, tokenFeesBefore);
        assertEq(token.balanceOf(address(hook)), tokenFeesBefore);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        // The router settles native ETH from its own balance, so send enough to cover any swap
        return swapRouter.swap{value: zeroForOne ? 1 ether : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }
}
