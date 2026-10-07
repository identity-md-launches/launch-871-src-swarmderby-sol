// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby, IERC20, IArbSys} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";

/// @dev Only SwarmDerby is deployed. External calls are mocked at the brief's
/// IMD address and ArbSys; no token fixture, fork, or shared environment is used.
abstract contract DerbyCallTest is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant ARB = address(100);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant DAY = 20_733;
    bytes32 internal constant HASH = keccak256("offline L2 target block");
    SwarmDerby internal derby;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(DAY * 1 days + 1 hours);
        // Deployment itself must work before either dependency has code.
        assertEq(IMD.code.length, 0);
        derby = new SwarmDerby(address(this), IERC20(IMD), 0.15 ether, 0.5 ether);
        _resetCalls(1_000);
    }

    function _resetCalls(uint256 l2Block) internal {
        vm.clearMockedCalls();
        // mockCall injects a STOP byte at empty addresses. This is a call stub,
        // not token bytecode, and creates no token contract or token supply.
        vm.mockCall(IMD, IERC20.transferFrom.selector, abi.encode(true));
        vm.mockCall(IMD, IERC20.transfer.selector, abi.encode(true));
        _block(l2Block);
        vm.mockCall(ARB, IArbSys.arbBlockHash.selector, abi.encode(HASH));
    }

    function _block(uint256 n) internal {
        vm.mockCall(ARB, IArbSys.arbBlockNumber.selector, abi.encode(n));
    }

    function _buy(address player, uint8 league, uint256 count) internal {
        vm.prank(player);
        derby.buyTurns(league, count);
    }

    function _commit(address player, uint8 league, bytes32 salt) internal returns (uint256 id) {
        bytes32 commitment = derby.commitFor(salt, player);
        vm.prank(player);
        id = derby.swing(league, 100, 100, commitment);
    }

    function _saltFor(uint256 id, uint8 wantedTier) internal pure returns (bytes32 salt) {
        // Fixture-only search: the hash is still unknown to a real committer.
        for (uint256 i; i < 20_000; ++i) {
            salt = keccak256(abi.encode("deterministic outcome", id, i));
            (uint8 tier,) = DerbyOdds.roll(keccak256(abi.encode(salt, HASH)), id, 100, 100);
            if (tier == wantedTier) return salt;
        }
        revert("test could not find requested outcome");
    }

    function _score(address player, uint8 league, uint8 tier) internal returns (uint256 id) {
        bytes32 salt = _saltFor(derby.nextSwingId(), tier);
        _block(1_000);
        id = _commit(player, league, salt);
        _block(1_006);
        (uint8 actual,) = derby.finalize(id, salt);
        assertEq(actual, tier);
    }

    function _close() internal {
        vm.warp((derby.currentDay() + 1) * 1 days);
        _block(2_000);
    }

    function _state(uint8 league, address player) internal view returns (bytes32) {
        uint256[] memory days_ = derby.openDays(league);
        uint256[] memory pots = new uint256[](days_.length);
        for (uint256 i; i < days_.length; ++i) {
            pots[i] = derby.dayPot(league, days_[i]);
        }
        return keccak256(
            abi.encode(
                derby.pot(league),
                derby.vault(league),
                derby.opsBalance(),
                derby.rollover(league),
                derby.turns(league, player),
                derby.settledDays(league),
                days_,
                pots,
                derby.nextSwingId(),
                derby.arcadeSwings(derby.currentDay(), player)
            )
        );
    }
}
