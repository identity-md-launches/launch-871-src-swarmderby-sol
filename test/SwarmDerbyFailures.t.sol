// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {SwarmDerby, IERC20, IArbSys} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";
import {DerbyCallTest} from "./helpers/DerbyCallTest.sol";

contract SwarmDerbyFailuresTest is DerbyCallTest {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_refusedPurchaseIsAtomic(uint8 leagueSeed, uint8 modeSeed, uint96 countSeed, bool packs) public {
        uint8 league = leagueSeed % 2;
        uint8 mode = modeSeed % 4;
        uint256 count = bound(countSeed, 1, 100);
        _buy(ALICE, league, 2);
        // Rollback must also remove a newly appended day, not just zero balances.
        vm.warp((DAY + 1) * 1 days);
        bytes32 before_ = _state(league, ALICE);
        bytes4 selector = mode < 2 ? IERC20.transferFrom.selector : IERC20.transfer.selector;
        if (mode % 2 == 0) vm.mockCall(IMD, selector, abi.encode(false));
        else vm.mockCallRevert(IMD, selector, abi.encodeWithSignature("Error(string)", "refused"));
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        if (packs) derby.buyPacks(league, count);
        else derby.buyTurns(league, count);
        assertEq(_state(league, ALICE), before_, "failed payment changed accounting");
        assertEq(derby.dayPot(league, DAY + 1), 0);
    }

    function test_emptyTokenReturnDataIsSupported() public {
        vm.mockCall(IMD, IERC20.transferFrom.selector, bytes(""));
        vm.mockCall(IMD, IERC20.transfer.selector, bytes(""));
        vm.expectCall(IMD, abi.encodeCall(IERC20.transferFrom, (ALICE, address(derby), 0.5 ether)));
        vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (derby.DEAD(), 0.2 ether)));
        vm.prank(ALICE);
        derby.buyPacks(1, 1);
        assertEq(derby.turns(1, ALICE), 5);
        assertEq(derby.pot(1) + derby.vault(1) + derby.opsBalance(), 0.3 ether);
    }

    function test_maximumPurchaseCountsRevertWithoutCredit() public {
        bytes32 before_ = _state(0, ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(stdError.arithmeticError);
        derby.buyTurns(0, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        derby.buyPacks(0, type(uint256).max);
        vm.stopPrank();
        assertEq(_state(0, ALICE), before_);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_invalidLeagueCannotSpendOrCreateActivity(uint8 invalidSeed) public {
        uint8 league = uint8(bound(invalidSeed, 2, 255));
        _buy(ALICE, 0, 1);
        bytes32 before_ = _state(0, ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyTurns(league, 1);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyPacks(league, 1);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.swing(league, 0, 0, bytes32(0));
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.settleNextDay(league);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.nextSettlement(league);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.openDays(league);
        vm.stopPrank();
        assertEq(_state(0, ALICE), before_);
    }

    function test_rejectedSwingDoesNotSpendTurnCapOrIdentifier() public {
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.NoTurns.selector);
        derby.swing(0, 0, 0, bytes32(0));
        _buy(ALICE, 0, 1);
        bytes32 before_ = _state(0, ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(SwarmDerby.BadCommit.selector);
        derby.swing(0, 100, 100, bytes32(0));
        vm.expectRevert(SwarmDerby.BadQuality.selector);
        derby.swing(0, 101, 100, bytes32(uint256(1)));
        vm.expectRevert(SwarmDerby.BadQuality.selector);
        derby.swing(0, 100, 101, bytes32(uint256(1)));
        vm.stopPrank();
        assertEq(_state(0, ALICE), before_);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(type(uint256).max, bytes32(0));
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(type(uint256).max);
    }

    function test_unauthorizedAdminCallsCannotChangeFundedState() public {
        _buy(ALICE, 0, 10);
        bytes32 before_ = _state(0, ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(1 ether, 5 ether);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.withdrawOps(ALICE, 1);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.transferOwnership(ALICE);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.acceptOwnership();
        vm.stopPrank();
        assertEq(_state(0, ALICE), before_);
        assertEq(derby.singlePrice(), 0.15 ether);
        assertEq(derby.packPrice(), 0.5 ether);
        assertEq(derby.owner(), address(this));
        assertEq(derby.pendingOwner(), address(0));
    }

    function test_failedOpsWithdrawalRestoresBalanceAndCannotReachPrizes() public {
        _buy(ALICE, 0, 10);
        uint256 ops = derby.opsBalance();
        bytes32 before_ = _state(0, ALICE);
        vm.mockCall(IMD, IERC20.transfer.selector, abi.encode(false));
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.withdrawOps(BOB, ops);
        assertEq(_state(0, ALICE), before_);
        vm.expectRevert(stdError.arithmeticError);
        derby.withdrawOps(BOB, ops + 1);
        assertEq(_state(0, ALICE), before_);
        _resetCalls(1_000);
        vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (BOB, ops)));
        derby.withdrawOps(BOB, ops);
        assertEq(derby.opsBalance(), 0);
        assertEq(derby.pot(0), 0.675 ether);
        assertEq(derby.vault(0), 0.15 ether);
    }

    function test_refusedSettlerTipRollsBackAndAnotherCallerCanSettle() public {
        _buy(ALICE, 0, 10);
        _score(ALICE, 0, DerbyOdds.HOMER);
        _close();
        bytes32 before_ = _state(0, ALICE);
        vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, BOB), abi.encode(false));
        vm.prank(BOB);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.settleNextDay(0);
        assertEq(_state(0, ALICE), before_);
        derby.settleNextDay(0);
        assertEq(derby.settledDays(0), 1);
        assertEq(derby.openDays(0).length, 0);
        vm.expectRevert(SwarmDerby.NothingToSettle.selector);
        derby.settleNextDay(0);
    }

    function test_allRefusedWinnersRollOverAndDoNotStallQueue() public {
        _buy(ALICE, 1, 10);
        _buy(BOB, 1, 10);
        _score(ALICE, 1, DerbyOdds.HOMER);
        _score(BOB, 1, DerbyOdds.BOMB);
        _close();
        (,,, uint256 amount, uint256 tip) = derby.nextSettlement(1);
        vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, ALICE), abi.encode(false));
        vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transfer.selector, BOB), bytes("blocked"));
        vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (address(this), tip)));
        derby.settleNextDay(1);
        assertEq(derby.rollover(1), amount - tip);
        assertEq(derby.pot(1), amount - tip);
        assertEq(derby.dayPot(1, DAY), 0);
        assertEq(derby.settledDays(1), 1);
        _buy(ALICE, 1, 1);
        _close();
        derby.settleNextDay(1);
        assertEq(derby.settledDays(1), 2);
        assertEq(derby.pot(1), amount - tip + 0.0675 ether);
    }

    function test_hashFailureOrZeroHashFinalizesAsFoulExactlyOnce() public {
        _buy(ALICE, 0, 2);
        for (uint256 mode; mode < 2; ++mode) {
            _resetCalls(1_000);
            bytes32 salt = bytes32(mode + 1);
            uint256 id = _commit(ALICE, 0, salt);
            _block(1_006);
            if (mode == 0) vm.mockCallRevert(ARB, IArbSys.arbBlockHash.selector, bytes("unavailable"));
            else vm.mockCall(ARB, IArbSys.arbBlockHash.selector, abi.encode(bytes32(0)));
            (uint8 tier, uint16 feet) = derby.finalize(id, salt);
            assertEq(tier, DerbyOdds.FOUL);
            assertEq(feet, 0);
            assertEq(derby.dayScore(0, DAY, ALICE), 0);
            vm.expectRevert(SwarmDerby.WrongStatus.selector);
            derby.finalize(id, salt);
            vm.expectRevert(SwarmDerby.WrongStatus.selector);
            derby.expire(id);
        }
    }

    function test_revealAndExpiryHaveComplementaryWindowBoundaries() public {
        _buy(ALICE, 0, 2);
        bytes32 salt = bytes32(uint256(7));
        uint256 id = _commit(ALICE, 0, salt);
        _block(1_005);
        vm.expectRevert(SwarmDerby.TooEarly.selector);
        derby.finalize(id, salt);
        _block(1_260); // target + 255, the last valid reveal block
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id);
        derby.finalize(id, salt);
        _block(2_000);
        id = _commit(ALICE, 0, salt);
        _block(2_261);
        derby.expire(id);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, salt);
        assertEq(derby.turns(0, ALICE), 0, "expiry must not refund a turn");
    }

    function test_failedSessionRotationKeepsOldBindingAndNonce() public {
        uint256 oldPk = 0x12345;
        uint256 newPk = 0x56789;
        address oldKey = vm.addr(oldPk);
        address newKey = vm.addr(newPk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oldPk, derby.sessionDigest(ALICE, oldKey));
        vm.prank(ALICE);
        derby.setSession(oldKey, abi.encodePacked(r, s, v));
        (v, r, s) = vm.sign(newPk, derby.sessionDigest(BOB, newKey));
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(newKey, abi.encodePacked(r, s, v));
        assertEq(derby.sessionOf(ALICE), oldKey);
        assertEq(derby.sessionPlayer(oldKey), ALICE);
        assertEq(derby.sessionNonce(oldKey), 1);
        assertEq(derby.sessionPlayer(newKey), address(0));
        assertEq(derby.sessionNonce(newKey), 0);
    }

    function test_sessionConsentRejectsMalformedMalleableAndWrongDomainSignatures() public {
        uint256 pk = 0x12345;
        address key = vm.addr(pk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, derby.sessionDigest(ALICE, key));
        bytes[] memory invalid = new bytes[](4);
        invalid[0] = bytes("");
        invalid[1] = abi.encodePacked(r, s); // 64 bytes, not the accepted 65
        invalid[2] = abi.encodePacked(r, s, uint8(29));
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        invalid[3] = abi.encodePacked(r, bytes32(order - uint256(s)), uint8(v == 27 ? 28 : 27));
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(ALICE);
            vm.expectRevert(SwarmDerby.BadSession.selector);
            derby.setSession(key, invalid[i]);
        }
        vm.chainId(4664);
        vm.prank(ALICE);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(key, abi.encodePacked(r, s, v));
        assertEq(derby.sessionNonce(key), 0);
        assertEq(derby.sessionOf(ALICE), address(0));
        vm.chainId(4663);
        vm.prank(ALICE);
        derby.setSession(key, abi.encodePacked(r, s, uint8(v - 27)));
        assertEq(derby.playerOf(key), ALICE);
    }
}
