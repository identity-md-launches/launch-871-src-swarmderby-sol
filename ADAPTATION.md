# SwarmDerby launch adaptation

SwarmDerby already meets the contracts-only factory requirements. No application
source changes were required, and no critical or high issue was reproduced in
this review. `src/SwarmDerby.sol` and `src/DerbyOdds.sol` remain byte-identical to
the supplied project. The ABI, events, errors, constants, prices, 40/45/10/5
purchase split, odds and payout math are preserved.

## Delivered changes

| File | Change and reason |
| --- | --- |
| `test/SwarmDerby.t.sol` | Route the two ArbSys read selectors to the existing mock with `vm.mockFunction`. Foundry 1.8.5's native ArbSys handling otherwise returns block 1 despite the fixture's `setBlock(1000)`, causing 18 original tests to fail. This repairs test-runner compatibility without altering any of the 54 test cases, assertions or application code. |
| `test/SwarmDerbyLaunch.t.sol` | Add three offline regression tests for factory deployment, purchase rollback without token code, and the protected runtime limits. They cover the empty-chain rehearsal that previously blocked launch #867, using the exact requested IMD address and prices. |
| `ADAPTATION.md` | Record the deployment arguments, audit dispositions, unchanged behavior and local verification required by this assignment. |

Build configuration, dependencies and browser odds code are unchanged. No
dependencies were installed. The original 54 test cases retain their behavior;
only their shared ArbSys setup changes.

## Deployment handoff

Launch kind: `evm_contracts`. Target: Robinhood Chain, chain ID 4663.
Deploy **only** `src/SwarmDerby.sol:SwarmDerby`, with zero ETH and these arguments
in order:

| Argument | ABI type | Value |
| --- | --- | --- |
| `owner_` | `address` | `$owner` |
| `imd_` | `address` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| `singlePrice_` | `uint256` | `150000000000000000` |
| `packPrice_` | `uint256` | `500000000000000000` |

The nonpayable constructor fully configures the application and assigns ownership
to `owner_`, independently of the factory's `msg.sender`. It requires neither
initialization calls nor code at IMD or ArbSys during deployment. The constructor
must continue accepting this nonzero token address without checking its code;
`_pull` rejects purchases with `NotAContract()` until the token exists.

`DerbyOdds` uses internal functions and needs no linked library deployment.
No token, distributor or pool is added. `DerbyLaunchProbe` is test scaffolding
only. The launch tests install no token or ArbSys fixture and assert that the
SwarmDerby constructor creates no additional contracts. The manifest belongs to
the subsequent launch step; no `launch.json` or broadcast is produced here.

The existing configuration already specifies Solidity 0.8.26, optimizer runs
2000, `via_ir = true`, and `bytecode_hash = "none"`. SwarmDerby's compiled runtime
is 12,599 bytes (limit 24,576); init code with these four arguments is 13,063
bytes (limit 49,152). Review found no proxy, initializer, token minting,
balance-freezing or confiscation capability. The runtime opcode scan skips PUSH
data and rejects DELEGATECALL, CALLCODE and SELFDESTRUCT.

## Imported audit dispositions

The brief reports the earlier audit job
`9396db7f-19f5-40b7-aa19-46b45ab87101` as having no critical, high or medium
findings. The four separately supplied imported findings were checked as follows.
The specific instruction to preserve this audited application unless a critical
or high issue reproduces governs the low finding below.

1. **Low: turns purchased before session binding**
   (`60b4ab8e09e7f3465a021d0cee0f1e6328421071e029ff3bede55b0a31c5ab67`).
   Reproduced locally: a key buys a turn for itself, signs consent and binds to a
   player with no turns. Its swing then reverts `NoTurns` while its own turn
   balance remains one. Both `leaveSession` and player revocation restore the
   key's ability to spend that turn. This is a recoverable low-severity usability
   limitation, not permanent loss or a critical/high issue. Left unchanged under
   the brief's preservation requirement. Binding first makes subsequent purchases
   credit the player; an already affected key can leave or be revoked.

2. **Info: owner runtime powers**
   (`3b2a1fb1e95e79bb23fb47de7f1d378619acbc13ac5aec9437b22446fabe2a7b`).
   Reproduced locally: after `setPrices(1 ether, 5 ether)`, a single purchase costs
   1 IMD. A price below the floor reverts `BadPrice`; withdrawing `opsBalance + 1`
   reverts without touching prize balances. Existing tests cover two-step
   ownership and ops-only withdrawals. These are accepted runtime powers, not
   missing constructor configuration. No `maxCost` parameter or admin redesign
   was added. The owner's commitment not to change prices during play remains a
   trust assumption.

3. **Info: external IMD transfer restrictions**
   (`904976cfe00b71012df5e009e87aac53296ebed5d55bc1f6d5cca436c6fbc9b2`).
   Reproduced the application's failure behavior using the project's existing
   unit-test mocks: a blocked burn recipient rolls back the entire purchase;
   a blocked settler rolls back settlement, while an unblocked caller can settle;
   a refused ops transfer preserves `opsBalance`. Existing tests confirm refused
   winner prizes roll over and refused slam prizes remain in the vault.
   No new token fixture is part of deployment or its rehearsal. The chosen
   token's live code, metadata, transfer switch and blocklist state were not
   reverified by these offline checks; the supplied audit's live observations
   are historical evidence. Blocking only the burn address does not by itself
   block transfers to unrelated winners or settlers. No contract change is
   required for this external dependency assumption.

4. **Info: reveal window**
   (`836327c109b7d6fca9e736bee12b06c6e52e0f1e721cfb20818b98aabebac95d`).
   The existing `test_revealAtWindowEdgeStillCounts`, `test_lateRevealIsFoul` and
   `test_expireUnrevealed` reproduce the boundary: target + 255 can score;
   target + 256 is a foul and consumes the turn. The approximately 26-second
   duration comes from the imported audit's measured cadence, not a new live
   measurement. The implementation uses ArbSys block numbers/hashes for reveals
   and timestamps for UTC days. This accepted design remains unchanged.

No imported application behavior was dismissed as nonreproducible. Live token
administration and chain cadence were not independently remeasured. Consent
without a deadline, client-reported quality and velocity, the per-wallet arcade
cap, and the 10% league-vault grand-slam payout also remain as expressly accepted.

## Verification

Checks use the project's existing configuration and vendored forge-std, with
Foundry 1.8.5 and Solidity 0.8.26. No RPC, wallet key or deployment transaction is
needed by the delivered tests.

- `forge build`: passes; existing non-fatal lint warnings remain. No application
  change was justified by a reproduced critical or high finding.
- `forge test`: all 54 original tests and three added launch tests pass. The two
  original fuzz tests each run 256 cases; browser parity and reveal-boundary tests
  pass.
- The unmodified supplied `Contracts.protected.t.sol` was copied temporarily into
  `test/scratch/` and run with `IMD_PROJECT_COUNT=1`, chain ID 4663, local test-only
  factory/owner identities, and SwarmDerby's bytecode plus the exact static IMD
  address and prices. Its CREATE2 prediction, constructor rehearsal, runtime size
  and forbidden-opcode check pass. Neither IMD nor ArbSys code was installed.
- Six temporary audit-reproduction tests pass: both ways to recover pre-binding
  turns, purchase at an updated owner price, blocked burn rollback, blocked
  settler recovery through another caller, and refused ops withdrawal rollback.
  A separate temporary ArbSys compatibility test confirms that the mock's block
  number and hash are observed. These seven scratch tests were removed before
  the final build/test so verification matches the submitted test set.
- Source hashes match the initial read, and `git diff --check` passes. No
  Slither, Mythril, live-chain fork or site/browser end-to-end run was performed;
  browser parity is the project's existing Solidity vector test.

Source SHA-256 values, unchanged from the initial read:

```text
5874b12bd2190b3cc92a5cf6607a4800674b305d7b9fc3293e73167ecd133d2d  src/SwarmDerby.sol
9931884e49e10a163b9d5bba38eb1e6876b3c5a0d0d9b33a84a7e242e6eff28b  src/DerbyOdds.sol
```
