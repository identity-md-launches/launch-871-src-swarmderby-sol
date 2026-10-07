// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DerbyOdds} from "src/DerbyOdds.sol";
import {DerbyCallTest} from "./helpers/DerbyCallTest.sol";
import {DerbyHandler} from "./helpers/DerbyHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmDerbyInvariantTest is DerbyCallTest {
    DerbyHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new DerbyHandler(derby);
        // Seed real, public-ABI outcomes: a funded vault, a payable slam, a
        // refused slam and a settled board. Thus conservation is never vacuous.
        for (uint8 league; league < 2; ++league) {
            handler.buy(league, league, 10, true, false);
            bytes32 salt = _saltFor(derby.nextSwingId(), DerbyOdds.SLAM);
            handler.swing(league, league, 100, 100, salt, false);
            handler.advance(0, 6);
            handler.resolve(league, 0, league == 1);
        }
        handler.advance(1 days, 300);
        handler.settle(0, 0);
        handler.settle(1, 2);
        // Leave a committed swing for early/wrong-salt/expiry and repeat tests.
        handler.swing(2, 0, 100, 100, bytes32(uint256(99)), false);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = DerbyHandler.buy.selector;
        selectors[1] = DerbyHandler.swing.selector;
        selectors[2] = DerbyHandler.advance.selector;
        selectors[3] = DerbyHandler.resolve.selector;
        selectors[4] = DerbyHandler.settle.selector;
        selectors[5] = DerbyHandler.withdraw.selector;
        selectors[6] = DerbyHandler.session.selector;
        selectors[7] = DerbyHandler.failedPurchase.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_valueIsConservedAcrossBothLeagues() public view {
        handler.checkMoney();
    }

    function invariant_turnsSessionsAndFinalityMatchPublicActions() public view {
        handler.checkPlayersAndSwings();
    }

    function afterInvariant() public {
        handler.finish();
    }

    function test_publicSwingsExerciseTopTenEviction() public {
        for (uint256 a; a < 12; ++a) {
            uint256 id = derby.nextSwingId();
            bytes32 salt = _saltFor(id, DerbyOdds.HOMER);
            handler.swing(a, 1, 100, 100, salt, false);
            handler.advance(0, 6);
            handler.resolve(id, 0, false);
        }
        handler.checkBoard(1, derby.currentDay());
        (address[] memory players,) = derby.board(1, derby.currentDay());
        assertEq(players.length, 10);
        for (uint256 a; a < 12; ++a) {
            assertGt(derby.dayScore(1, derby.currentDay(), handler.actor(a)), 0);
        }
        handler.finish();
    }

    function test_handlerExercisesPayoutFailureSessionAndClosurePaths() public {
        assertEq(handler.slamCalls(), 2);
        assertEq(handler.settlementCalls(), 2);
        assertGt(handler.vaultOut(0), 0);
        assertEq(handler.vaultOut(1), 0);
        handler.session(3, 0);
        handler.buy(3, 1, 1, true, true);
        handler.swing(3, 1, 100, 100, bytes32(uint256(333)), true);
        handler.resolve(3, 2, false);
        handler.resolve(3, 0, false);
        handler.advance(1, 6);
        handler.resolve(3, 0, false);
        handler.resolve(3, 0, false);
        handler.failedPurchase(3, 1, true);
        handler.withdraw(type(uint256).max, true);
        handler.withdraw(type(uint256).max, false);
        handler.session(3, 2);
        handler.finish();
        assertGt(handler.resolvedCalls(), 2);
        assertGt(handler.rejectedCalls(), 0);
    }
}
