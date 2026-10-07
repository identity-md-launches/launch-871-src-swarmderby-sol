# Additional SwarmDerby coverage

Run with `forge build` and `forge test`. No new dependencies, environment variables,
RPC access, or configuration changes are required. The earlier tests, launch
rehearsal, browser parity vectors, and both production sources are unchanged.

`SwarmDerbyFailures.t.sol` adds atomic rollback checks for refused pulls, burns,
ops withdrawals and settler tips; winner-refusal queue progress; invalid leagues,
overflow counts and unauthorized administration; reveal/expiry boundaries and
unavailable block hashes; and malformed, malleable, wrong-player and wrong-chain
session consent. Fuzz tests use 1,000 runs with bounded inputs.

`SwarmDerbyInvariant.t.sol` targets eight handler actions with 12 players and
dedicated session keys, for 256 sequences of 64 calls per invariant. Unexpected
reverts fail the run. Expected failures assert the precise error. The handler uses
only the unchanged application's public ABI and never inserts scores or balances
into its storage. Seeded public calls guarantee payable and refused slams and
settlements are exercised even in a short random sequence.

The properties check:

- Purchases equal burns, prizes, withdrawn ops, and remaining obligations.
- Each league's pot equals its rollover plus the pots of all queued days.
- Each league's pot and vault reconcile with separate cumulative inflows/outflows.
- Queued days stay ordered and unique; settlement advances exactly once.
- Purchased turns equal spent plus remaining turns for each player and league.
- Session keys receive no stranded turns; bindings and nonces match consent actions.
- Arcade limits and every swing's identity, commitment, day and terminal status
  match the history of public calls.
- Boards reflect the players' longest arcade homer or cumulative agent feet,
  contain the top ten without duplicates, and remain sorted.
- After each sequence, pending swings can expire and every queued day can settle.

The supplied invariant-discovery and property-testing references informed the
conservation, transition, bounded-input and non-vacuity checks. The tests are
original project-specific code; no upstream template or dependency is vendored.

## Offline integration boundary

The added tests deploy no token fixture. They use Foundry call stubs at
`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` and ArbSys, after deploying
SwarmDerby with the requested constructor arguments. Foundry's `mockCall` injects
a STOP byte into an empty account; it does not deploy token code or create supply.
The separate existing launch rehearsal still runs with no dependency code.

The invariant ledger models exact ERC-20 transfers and selected refusals.
`expectCall` checks transfer calldata, including payer, beneficiary and amount.
This is a model of cash flows, not a measurement of a deployed token's balances.
Live Robinhood Chain token behavior and ArbSys integration remain unverified by
these offline tests. A fork against the actual dependencies is still owed before
claiming live-chain integration coverage.
