// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby, IERC20, IArbSys} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";

/// @dev Drives the unchanged public ABI. The ghost ledger models exact-transfer
/// IMD calls, including refusals. expectCall verifies the payer, recipient and
/// amount independently of SwarmDerby's balance getters. It is not a live-token
/// balance oracle; token code, callbacks and chain integration need a fork run.
contract DerbyHandler is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 internal constant HASH = keccak256("offline L2 target block");
    uint256 public constant ACTORS = 12;
    SwarmDerby public immutable derby;
    address internal immutable owner;
    address internal constant KEEPER = address(0xC011EC7);
    address[12] internal keys;

    struct Play {
        address player;
        uint8 league;
        uint8 quality;
        uint8 velo;
        uint64 target;
        uint32 day;
        bytes32 salt;
        bool final_;
    }

    Play[] internal plays;
    uint256 public l2Block = 1_000;
    uint256 public purchased;
    uint256 public burned;
    uint256 public prizes;
    uint256 public opsWithdrawn;
    uint256 public opsAccrued;
    uint256[2] public potIn;
    uint256[2] public potOut;
    uint256[2] public vaultIn;
    uint256[2] public vaultOut;
    uint256[2] public settled;
    uint256[2] public lastSettledDay;
    uint256 public resolvedCalls;
    uint256 public rejectedCalls;
    uint256 public slamCalls;
    uint256 public settlementCalls;
    mapping(uint8 => mapping(address => uint256)) public bought;
    mapping(uint8 => mapping(address => uint256)) public spent;
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public scores;
    mapping(uint256 => mapping(address => uint256)) public arcadeUsed;
    mapping(address => bool) public boundSession;
    mapping(address => uint256) public binds;

    constructor(SwarmDerby derby_) {
        derby = derby_;
        owner = derby_.owner();
        for (uint256 i; i < ACTORS; ++i) {
            keys[i] = vm.addr(0xD30000 + i);
        }
    }

    function actor(uint256 seed) public pure returns (address) {
        return address(uint160(0x10000 + seed % ACTORS));
    }

    function key(uint256 seed) public view returns (address) {
        return keys[seed % ACTORS];
    }

    function _resetCalls() internal {
        vm.clearMockedCalls();
        vm.mockCall(IMD, IERC20.transferFrom.selector, abi.encode(true));
        vm.mockCall(IMD, IERC20.transfer.selector, abi.encode(true));
        vm.mockCall(address(100), IArbSys.arbBlockNumber.selector, abi.encode(l2Block));
        vm.mockCall(address(100), IArbSys.arbBlockHash.selector, abi.encode(HASH));
    }

    function _caller(uint256 seed, bool useSession) internal view returns (address) {
        address player = actor(seed);
        return useSession && boundSession[player] ? key(seed) : player;
    }

    function buy(uint256 actorSeed, uint8 leagueSeed, uint256 countSeed, bool packs, bool useSession) public {
        _resetCalls();
        uint8 league = leagueSeed % 2;
        uint256 count = bound(countSeed, 1, 25);
        uint256 cost = count * (packs ? 0.5 ether : 0.15 ether);
        uint256 turns_ = count * (packs ? 5 : 1);
        address player = actor(actorSeed);
        address caller = _caller(actorSeed, useSession);
        vm.expectCall(IMD, abi.encodeCall(IERC20.transferFrom, (caller, address(derby), cost)));
        vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (derby.DEAD(), cost * 2 / 5)));
        vm.prank(caller);
        if (packs) derby.buyPacks(league, count);
        else derby.buyTurns(league, count);
        bought[league][player] += turns_;
        purchased += cost;
        burned += cost * 2 / 5;
        potIn[league] += cost * 45 / 100;
        vaultIn[league] += cost / 10;
        opsAccrued += cost / 20;
    }

    function swing(
        uint256 actorSeed,
        uint8 leagueSeed,
        uint8 qualitySeed,
        uint8 veloSeed,
        bytes32 salt,
        bool useSession
    ) public {
        uint8 league = leagueSeed % 2;
        address player = actor(actorSeed);
        uint8 quality = uint8(bound(qualitySeed, 0, 100));
        uint8 velo = uint8(bound(veloSeed, 0, 100));
        // Supply prerequisites so long sequences exercise resolution and settlement.
        if (bought[league][player] == spent[league][player]) buy(actorSeed, league, 1, true, useSession);
        uint256 day = derby.currentDay();
        address caller = _caller(actorSeed, useSession);
        bytes32 commitment = derby.commitFor(salt, player);
        if (league == 0 && arcadeUsed[day][player] == 20) {
            vm.prank(caller);
            vm.expectRevert(SwarmDerby.DailyCapReached.selector);
            derby.swing(league, quality, velo, commitment);
            ++rejectedCalls;
            return;
        }
        vm.prank(caller);
        uint256 id = derby.swing(league, quality, velo, commitment);
        assertEq(id, plays.length, "swing ids must be unique and sequential");
        ++spent[league][player];
        if (league == 0) ++arcadeUsed[day][player];
        plays.push(
            Play(player, league, quality, velo, uint64(quality == 0 ? 0 : l2Block + 5), uint32(day), salt, quality == 0)
        );
    }

    function advance(uint256 secondsSeed, uint256 blocksSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 1 days + 1));
        l2Block += bound(blocksSeed, 1, 300);
        vm.mockCall(address(100), IArbSys.arbBlockNumber.selector, abi.encode(l2Block));
    }

    /// @param modeSeed 0: reveal, 1: expire, 2: wrong salt. Repeated resolution is
    /// deliberately attempted too; expected errors are caught, unexpected ones fail.
    function resolve(uint256 idSeed, uint8 modeSeed, bool refusePrize) public {
        if (plays.length == 0) return;
        _resetCalls();
        uint256 id = idSeed % plays.length;
        Play storage p = plays[id];
        uint8 mode = modeSeed % 3;
        if (p.final_) {
            vm.expectRevert(SwarmDerby.WrongStatus.selector);
            if (mode == 1) derby.expire(id);
            else derby.finalize(id, p.salt);
            ++rejectedCalls;
            return;
        }
        if (mode == 2) {
            vm.expectRevert(SwarmDerby.BadSalt.selector);
            derby.finalize(id, bytes32(uint256(p.salt) ^ 1));
            ++rejectedCalls;
            return;
        }
        if (mode == 1) {
            if (l2Block <= uint256(p.target) + 255) {
                vm.expectRevert(SwarmDerby.NotExpired.selector);
                derby.expire(id);
                ++rejectedCalls;
                return;
            }
            derby.expire(id);
        } else {
            if (l2Block <= p.target) {
                vm.expectRevert(SwarmDerby.TooEarly.selector);
                derby.finalize(id, p.salt);
                ++rejectedCalls;
                return;
            }
            uint256 vaultBefore = vaultIn[p.league] - vaultOut[p.league];
            (uint8 expectedTier,) = l2Block - p.target <= 255
                ? DerbyOdds.roll(keccak256(abi.encode(p.salt, HASH)), id, p.quality, p.velo)
                : (uint8(DerbyOdds.FOUL), uint16(0));
            if (refusePrize) {
                vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, p.player), abi.encode(false));
            }
            if (expectedTier == DerbyOdds.SLAM && vaultBefore / 10 != 0) {
                vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (p.player, vaultBefore / 10)));
            }
            (uint8 tier, uint16 feet) = derby.finalize(id, p.salt);
            assertEq(tier, expectedTier);
            if (tier >= DerbyOdds.HOMER) {
                if (p.league == 1) scores[p.league][p.day][p.player] += feet;
                else if (feet > scores[p.league][p.day][p.player]) scores[p.league][p.day][p.player] = feet;
            }
            if (tier == DerbyOdds.SLAM) {
                ++slamCalls;
                if (!refusePrize) {
                    vaultOut[p.league] += vaultBefore / 10;
                    prizes += vaultBefore / 10;
                }
            }
        }
        p.final_ = true;
        ++resolvedCalls;
        checkBoard(p.league, p.day);
    }

    /// @param refusalSeed 0: all transfers work, 1: one winner refuses,
    /// 2: all winners refuse, 3: the caller refuses its tip (atomic revert).
    function settle(uint8 leagueSeed, uint8 refusalSeed) public {
        _resetCalls();
        uint8 league = leagueSeed % 2;
        uint8 refusal = refusalSeed % 4;
        (bool exists, bool ready, uint256 day, uint256 amount, uint256 quotedTip) = derby.nextSettlement(league);
        if (!exists || !ready) {
            vm.expectRevert(exists ? SwarmDerby.DayNotOver.selector : SwarmDerby.NothingToSettle.selector);
            derby.settleNextDay(league);
            ++rejectedCalls;
            return;
        }
        checkBoard(league, day);
        (address[] memory players,) = derby.board(league, day);
        uint256 distributable = amount * 9 / 10;
        uint256 tip = players.length == 0 ? 0 : distributable / 200;
        assertEq(quotedTip, tip);
        if (tip != 0) vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (KEEPER, tip)));
        if (refusal == 3 && tip != 0) {
            bytes32 before_ = _moneyState(league);
            vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, KEEPER), abi.encode(false));
            vm.prank(KEEPER);
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.settleNextDay(league);
            assertEq(_moneyState(league), before_, "refused tip consumed the day");
            ++rejectedCalls;
            return;
        }
        uint256 paid = tip;
        uint256[3] memory shares = [uint256(60), 25, 15];
        for (uint256 i; i < players.length && i < 3; ++i) {
            uint256 award = (distributable - tip) * shares[i] / 100;
            bool refuses = refusal == 2 || (refusal == 1 && i == 0);
            if (refuses) {
                vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, players[i]), abi.encode(false));
            } else {
                paid += award;
            }
            if (award != 0) vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (players[i], award)));
        }
        vm.prank(KEEPER);
        derby.settleNextDay(league);
        assertEq(derby.rollover(league), amount - paid, "unpaid shares and dust must remain");
        assertEq(derby.dayPot(league, day), 0);
        if (settled[league] != 0) assertGt(day, lastSettledDay[league]);
        lastSettledDay[league] = day;
        ++settled[league];
        ++settlementCalls;
        potOut[league] += paid;
        prizes += paid;
    }

    function withdraw(uint256 amountSeed, bool refuse) public {
        _resetCalls();
        uint256 available = opsAccrued - opsWithdrawn;
        uint256 amount = bound(amountSeed, 0, available);
        if (amount != 0) vm.expectCall(IMD, abi.encodeCall(IERC20.transfer, (owner, amount)));
        if (refuse && amount != 0) {
            vm.mockCall(IMD, IERC20.transfer.selector, abi.encode(false));
            vm.prank(owner);
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.withdrawOps(owner, amount);
            assertEq(derby.opsBalance(), available);
            ++rejectedCalls;
        } else {
            vm.prank(owner);
            derby.withdrawOps(owner, amount);
            opsWithdrawn += amount;
        }
    }

    function session(uint256 actorSeed, uint8 modeSeed) public {
        address player = actor(actorSeed);
        address sessionKey = key(actorSeed);
        uint8 mode = modeSeed % 3;
        if (mode == 0) {
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(0xD30000 + actorSeed % ACTORS, derby.sessionDigest(player, sessionKey));
            vm.prank(player);
            derby.setSession(sessionKey, abi.encodePacked(r, s, v));
            boundSession[player] = true;
            ++binds[player];
        } else if (mode == 1) {
            vm.prank(player);
            derby.setSession(address(0), "");
            boundSession[player] = false;
        } else if (boundSession[player]) {
            vm.prank(sessionKey);
            derby.leaveSession();
            boundSession[player] = false;
        } else {
            vm.prank(sessionKey);
            vm.expectRevert(SwarmDerby.BadSession.selector);
            derby.leaveSession();
            ++rejectedCalls;
        }
    }

    function failedPurchase(uint256 actorSeed, uint8 leagueSeed, bool failBurn) public {
        _resetCalls();
        uint8 league = leagueSeed % 2;
        address player = actor(actorSeed);
        bytes32 before_ = _moneyState(league);
        uint256 turnsBefore = derby.turns(league, player);
        vm.mockCall(IMD, failBurn ? IERC20.transfer.selector : IERC20.transferFrom.selector, abi.encode(false));
        vm.prank(player);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.buyPacks(league, 1);
        assertEq(_moneyState(league), before_);
        assertEq(derby.turns(league, player), turnsBefore);
        ++rejectedCalls;
    }

    function _moneyState(uint8 league) internal view returns (bytes32) {
        uint256[] memory days_ = derby.openDays(league);
        uint256[] memory pots = new uint256[](days_.length);
        for (uint256 i; i < days_.length; ++i) {
            pots[i] = derby.dayPot(league, days_[i]);
        }
        return keccak256(
            abi.encode(
                derby.pot(league),
                derby.vault(league),
                derby.rollover(league),
                derby.opsBalance(),
                derby.settledDays(league),
                days_,
                pots
            )
        );
    }

    function checkBoard(uint8 league, uint256 day) public view {
        (address[] memory players, uint256[] memory values) = derby.board(league, day);
        uint256 scorers;
        for (uint256 a; a < ACTORS; ++a) {
            address player = actor(a);
            uint256 score = scores[league][day][player];
            assertEq(derby.dayScore(league, day, player), score, "score attributed to wrong day or actor");
            if (score != 0) ++scorers;
            bool included;
            for (uint256 i; i < players.length; ++i) {
                if (players[i] == player) included = true;
            }
            if (!included && players.length != 0) assertLe(score, values[values.length - 1]);
        }
        assertEq(players.length, scorers < 10 ? scorers : 10);
        for (uint256 i; i < players.length; ++i) {
            assertGt(values[i], 0);
            assertEq(values[i], scores[league][day][players[i]]);
            if (i != 0) assertGe(values[i - 1], values[i]);
            for (uint256 j; j < i; ++j) {
                assertTrue(players[i] != players[j], "duplicate board entry");
            }
        }
    }

    function checkMoney() public view {
        uint256 held = derby.opsBalance();
        assertEq(held, opsAccrued - opsWithdrawn);
        for (uint8 league; league < 2; ++league) {
            assertEq(derby.pot(league), potIn[league] - potOut[league]);
            assertEq(derby.vault(league), vaultIn[league] - vaultOut[league]);
            assertEq(derby.settledDays(league), settled[league]);
            uint256 sum = derby.rollover(league);
            uint256[] memory days_ = derby.openDays(league);
            for (uint256 i; i < days_.length; ++i) {
                if (i != 0) assertGt(days_[i], days_[i - 1], "day queued twice or out of order");
                if (settled[league] != 0) assertGt(days_[i], lastSettledDay[league]);
                sum += derby.dayPot(league, days_[i]);
            }
            assertEq(derby.pot(league), sum, "pot must equal all unsettled obligations");
            held += derby.pot(league) + derby.vault(league);
        }
        assertEq(held + burned + prizes + opsWithdrawn, purchased, "value created or lost");
    }

    function checkPlayersAndSwings() public view {
        for (uint256 a; a < ACTORS; ++a) {
            address player = actor(a);
            address sessionKey = key(a);
            for (uint8 league; league < 2; ++league) {
                assertEq(derby.turns(league, player) + spent[league][player], bought[league][player]);
                assertEq(derby.turns(league, sessionKey), 0, "turns stranded on session key");
            }
            uint256 used = arcadeUsed[derby.currentDay()][player];
            assertLe(used, 20);
            assertEq(derby.arcadeSwings(derby.currentDay(), player), used);
            assertEq(derby.arcadeSwingsLeft(player), 20 - used);
            assertEq(derby.sessionOf(player), boundSession[player] ? sessionKey : address(0));
            assertEq(derby.sessionPlayer(sessionKey), boundSession[player] ? player : address(0));
            assertEq(derby.sessionNonce(sessionKey), binds[player]);
        }
        assertEq(derby.nextSwingId(), plays.length);
        for (uint256 id; id < plays.length; ++id) {
            Play memory p = plays[id];
            (
                address player,
                uint8 league,
                uint8 q,
                uint8 v,
                SwarmDerby.Status status,
                uint64 target,
                bytes32 commitment,
                uint32 day
            ) = derby.swings(id);
            assertEq(player, p.player);
            assertEq(league, p.league);
            assertEq(q, p.quality);
            assertEq(v, p.velo);
            assertEq(uint8(status), uint8(p.final_ ? SwarmDerby.Status.Final : SwarmDerby.Status.Committed));
            assertEq(target, p.target);
            assertEq(commitment, p.quality == 0 ? bytes32(0) : derby.commitFor(p.salt, p.player));
            assertEq(day, p.day);
        }
    }

    /// @dev End-of-sequence liveness: every outstanding swing and queued day can
    /// be closed, and repeating closure cannot pay twice.
    function finish() public {
        advance(1 days + 1, 300);
        for (uint256 id; id < plays.length; ++id) {
            if (!plays[id].final_) resolve(id, 1, false);
        }
        for (uint8 league; league < 2; ++league) {
            while (derby.openDays(league).length != 0) settle(league, 0);
            assertEq(derby.pot(league), derby.rollover(league));
            vm.expectRevert(SwarmDerby.NothingToSettle.selector);
            derby.settleNextDay(league);
        }
        checkMoney();
        checkPlayersAndSwings();
    }
}
