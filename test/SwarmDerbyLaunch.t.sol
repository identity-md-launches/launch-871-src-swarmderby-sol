// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby} from "../src/SwarmDerby.sol";

/// @dev Test-only factory: deploy exactly the supplied init code with zero ETH.
contract DerbyLaunchProbe {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract SwarmDerbyLaunchTest is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 internal constant SINGLE_PRICE = 150000000000000000;
    uint256 internal constant PACK_PRICE = 500000000000000000;

    DerbyLaunchProbe internal factory;
    SwarmDerby internal derby;
    address internal launchOwner;

    function setUp() public {
        vm.chainId(4663);
        launchOwner = makeAddr("test launch owner");
        factory = new DerbyLaunchProbe();
        // Reproduce the empty-chain rehearsal that blocked launch #867. No token or
        // ArbSys fixture is installed; neither dependency is needed by the constructor.
        assertEq(IMD.code.length, 0);
        assertEq(address(100).code.length, 0);
        bytes memory initCode =
            abi.encodePacked(type(SwarmDerby).creationCode, abi.encode(launchOwner, IMD, SINGLE_PRICE, PACK_PRICE));
        assertLe(initCode.length, 49_152);
        bytes32 salt = keccak256("SwarmDerby launch rehearsal");
        address predicted = computeCreate2Address(salt, keccak256(initCode), address(factory));
        derby = SwarmDerby(factory.deploy(initCode, salt));
        assertEq(address(derby), predicted);
    }

    function test_factoryDeploymentIsFullyConfigured() public {
        assertEq(derby.owner(), launchOwner);
        assertEq(derby.pendingOwner(), address(0));
        assertEq(address(derby.imd()), IMD);
        assertEq(derby.singlePrice(), SINGLE_PRICE);
        assertEq(derby.packPrice(), PACK_PRICE);
        assertEq(address(derby).balance, 0);
        assertEq(IMD.code.length, 0);
        assertEq(vm.getNonce(address(derby)), 1, "constructor must not create other contracts");

        vm.prank(address(factory));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(SINGLE_PRICE, PACK_PRICE);
        vm.prank(launchOwner);
        derby.setPrices(SINGLE_PRICE, PACK_PRICE);
    }

    function test_missingTokenRejectsPurchasesWithoutCreditingState() public {
        address buyer = makeAddr("test buyer");
        uint256 day = derby.currentDay();
        for (uint8 league; league < 2; ++league) {
            vm.prank(buyer);
            vm.expectRevert(SwarmDerby.NotAContract.selector);
            derby.buyTurns(league, 1);
            vm.prank(buyer);
            vm.expectRevert(SwarmDerby.NotAContract.selector);
            derby.buyPacks(league, 1);
            assertEq(derby.turns(league, buyer), 0);
            assertEq(derby.pot(league), 0);
            assertEq(derby.dayPot(league, day), 0);
            assertEq(derby.vault(league), 0);
            assertEq(derby.rollover(league), 0);
            assertEq(derby.openDays(league).length, 0);
        }
        assertEq(derby.opsBalance(), 0);
        assertEq(IMD.code.length, 0);
    }

    function test_runtimeMeetsLaunchLimits() public view {
        bytes memory code = address(derby).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        // Match the protected floor: skip PUSH immediate data when scanning opcodes.
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
