# Decisions

Where the build differs from the handbook, or makes a choice the handbook leaves open, it is
recorded here (handbook rule 9). Newest last.

## Phase 1: repository and environment (2026-10-19)

### D-001: Node.js 22.12 or newer, CI on Node 24

The handbook says "Node.js 20 LTS or newer". Node 20 reached end of life on 2026-04-30, and
Vite 8 requires Node `^20.19 || >=22.12`. `package.json` sets `engines.node` to `>=22.12.0`, and
CI uses the active LTS (Node 24, from `.node-version`).

### D-002: TypeScript 5.9.3, not 7.x

TypeScript 7 (the native compiler) is the npm `latest` tag, but `typescript-eslint` 8.71 supports
only TypeScript `<6.1`. TypeScript 5.9.3 is the newest 5.x and matches the handbook's assumed
major version.

### D-003: pnpm 12.14.0, install scripts denied by default

pnpm is pinned through `packageManager` in `package.json`. pnpm 12 fails an install when a
dependency has an unapproved build script. `pnpm-workspace.yaml` denies `esbuild`'s script
(`allowBuilds: { esbuild: false }`), because it only re-checks the platform binary that pnpm
already installs as an optional dependency. Exact versions are enforced with `savePrefix: ""`.

### D-004: Solidity libraries come from pnpm, not git submodules

`contracts/` is a pnpm workspace package, in addition to the handbook's `packages/*` and
`apps/*`, so Solidity libraries are pinned in the same `pnpm-lock.yaml` as everything else and
a clean clone needs no `git submodule update`. `remappings.txt` points at
`contracts/node_modules/`.

The npm package named `forge-std` is an unofficial 2022 repackaging by a third party, so it was
rejected. `forge-std` is installed from the official `foundry-rs/forge-std` repository, pinned to
the v1.17.0 commit `f3dae6e6ee381f25eb6a246f7da9b85c91a68219`. OpenZeppelin Contracts (Phase 2)
will come from the official `@openzeppelin/contracts` npm package.

### D-005: one root `.env`; `pnpm dev` writes `.env.development.local`

The handbook has a single `.env.example` with every variable, and has `dev.sh` write
`apps/web/.env.local`. Here, Vite's `envDir` is the repository root, so the web app and the
scripts share one `.env`. `pnpm dev` writes the anvil settings to the root
`.env.development.local`. Vite loads that file only in dev mode, so `pnpm dev` talks to anvil and
`pnpm build` uses the testnet values in `.env`, with no manual switching.

Only `VITE_` variables reach the browser bundle. As a second guard, `apps/web/vite.config.ts`
refuses to build if a `VITE_` variable name looks like a secret (`PRIVATE`, `SECRET`,
`MNEMONIC`, `SEED`, `PASSWORD`, `API_KEY`).

### D-006: `scripts/dev.sh` delegates to `scripts/dev.ts`

The development machine runs Windows, so the dev orchestration is written in TypeScript (run
with `tsx`) and works the same everywhere. `./scripts/dev.sh` and `pnpm dev` are equivalent.

- anvil starts with `--silent`, because by default it prints its well-known development private
  keys, and the handbook forbids logging keys.
- Local deploys use `forge script --unlocked --sender <anvil account 0>`, so no private key
  appears anywhere in the repository. `DEPLOYER_PRIVATE_KEY` is removed from the environment of
  local forge runs, so a testnet key in the shell can never be used on anvil.
- If an anvil node is already running on port 8545, it is reused.

### D-007: Solidity 0.8.37, EVM version pinned to Prague

`solc_version = "0.8.37"`: the newest release, published 2026-09-10, and at least 0.8.24 as the
handbook requires. Newer solc versions default to a later EVM fork, so `evm_version = "prague"`
is pinned explicitly to the fork Base Sepolia supports. The default fuzz profile already uses
10,000 runs (Phase 2 acceptance).

### D-008: Python 3.11 alongside 3.14; Slither under 3.11

The machine already had Python 3.14. Python 3.11 (the handbook's version for Phase 6) was
installed beside it, and Slither 0.11.6 was installed under it. Run it with
`py -3.11 -m slither contracts` (Windows) or `slither contracts`.

### D-009: later-phase root scripts exist now, as honest stubs

The handbook's root scripts include `redteam`, `eval` and `evidence`, which depend on later
phases.

- `pnpm redteam` and `pnpm eval` load `redteam/cases/*.json` and `eval/tasks/*.json`. With zero
  cases they report that and exit 0, so CI passes on the skeleton. If any case exists before its
  runner does, they exit 1, so an unrun case can never count as a pass.
- `pnpm evidence` exits 1 with "not implemented yet (Phase 9)".

### D-010: GitHub Actions pinned to commit SHAs

CI actions are pinned to full commit SHAs, with the tag in a comment, so a moved tag cannot
change what CI runs. Annotated tags are dereferenced to their commits.

The runner image is pinned to `ubuntu-24.04` rather than `ubuntu-latest`, which GitHub moves to
Ubuntu 26 from 2026-10-19. Upgrading the OS image is then a deliberate change, not a silent one.

### D-011: the deploy script reads keys from the environment

`script/Deploy.s.sol` uses `vm.envUint("DEPLOYER_PRIVATE_KEY")` on testnet, and `--unlocked` on
anvil. `pnpm deploy:testnet` passes the key, RPC URL and Etherscan key to forge as environment
variables, never as command-line arguments. It refuses to broadcast unless the RPC reports chain
ID 84532. Basescan verification uses an Etherscan V2 API key, read from `BASESCAN_API_KEY`.

### D-012: newer major versions than the handbook lists

These were the current stable releases at build time (rule 5): Vite 8, Vitest 5, ESLint 10,
React 19.3, viem 2.57, Playwright 1.64 and Foundry 1.8.5. Phase 1 also includes a Playwright
smoke test (`pnpm test:e2e`). It is not yet in CI; the handbook's CI list adds end-to-end tests
in Phase 7.

## Phase 2: smart contracts (2026-10-19)

### D-013: a token's first `setTokenLimits` call enables it immediately

The handbook says cap decreases apply now and increases wait for the timelock. Read literally,
the owner's very first configuration (caps going up from zero) would also wait 24 hours,
blocking onboarding. So the first call for a token enables it at once (`TokenEnabled`). Every
later increase is timelocked. To switch agent spending off, set both caps to 0; switching it back
on is then an increase, so it is timelocked too. This keeps invariant 7 meaningful: after a token
is first configured, its caps never rise before an `eta`. `setTokenLimits` also rejects
`perTxCap > dailyCap`, and a new call replaces any queued increase.

### D-014: owner approvals bypass the agent's daily cap and the buffer

The handbook says `approveRequest` "pays even to non-allowlisted recipients and above caps; still
respects pause". Approved payments are the owner's own decision, so they do not count toward
`spent[token]` (which the handbook defines as "spent that day by the agent") and do not check
`minBuffer`. Requests expire after 72 hours. The approvals UI (Phase 7) shows the
post-payment balance.

### D-015: changing a recipient's cap means removing and re-adding it

`addRecipient` reverts with `RecipientAlreadyAdded` for an existing recipient. A higher cap
must not apply instantly, so the owner removes and re-adds the recipient, which restarts the
activation delay.

### D-016: fixed constants

`LIMIT_TIMELOCK` (24 hours), `MAX_SESSION_DURATION` (30 days), `REQUEST_TTL` (72 hours) and
`MAX_BATCH_SIZE` (10) are constants, since changing them would itself need a timelock. The
recipient delay is owner-settable, from 0 to 30 days (default 1 hour), and applies to recipients
added afterwards.

### D-017: intent ID rules

`bytes32(0)` is rejected (`InvalidIntent`). A batch marks its own intent ID as used as well as
each item's ID, so the same ID cannot drive both a batch and a single transfer. Item IDs are
`keccak256(abi.encode(batchIntentId, index))`, exposed as `itemIntentId()` for the engine. A
reverted call does not consume its intent ID.

### D-018: guardian powers

Per the handbook, the guardian may pause, revoke the session and cancel a queued limit increase.
It may also cancel a queued savings pool change, which is the same kind of timelocked change. It
cannot unpause, and cannot be the agent.

### D-019: named pause error, and no ownership renunciation

`_requireNotPaused` is overridden to revert with `WalletPaused()`, matching the handbook's
evidence list, instead of OpenZeppelin's `EnforcedPause()`. `renounceOwnership` always reverts
(`RenounceDisabled`), because a vault without an owner would lock its funds forever.

### D-020: savings details

`depositToSavings` requires the pool's asset to be an enabled token, respects `minBuffer`, and
resets the pool's allowance to 0 after depositing, so no allowance outlives the call (invariant
8). Savings moves are not spending and do not count toward the daily cap. The first savings pool
may be set immediately when none is set; later changes are timelocked (handbook 2.3).
`SavingsPool` uses a 6-digit virtual share offset (`_decimalsOffset`) against the ERC-4626
inflation attack (`test_SavingsPool_InflationAttackIsUneconomic`).

### D-021: SeedDemo is configurable and idempotent

The Base Sepolia faucet gives only 20 test USDC at a time, while the handbook's demo vault has a
50 USDC buffer and is "funded". So `SeedDemo.s.sol` takes `SEED_PER_TX`, `SEED_DAILY`,
`SEED_BUFFER`, `SEED_RECIPIENT_DELAY` and `SEED_FUND` overrides (handbook defaults otherwise).
On testnet it transfers what the deployer holds, up to `SEED_FUND`. Re-running reuses the vault.
The four contacts' addresses are derived from labels, so nobody holds their keys. Output goes to
`deployments/<chainId>-demo.json`. `pnpm dev` advances anvil's clock past the 1-hour recipient
delay after seeding, so local contacts are payable at once while the delay rule stays unchanged.

### D-022: raw-attack check script and typed ABIs

`pnpm raw-attack <local|testnet>` runs the Phase 2 acceptance check with no engine in the way.
A fresh in-memory agent key sends `executeTransfer` to `0x…dEaD` with a fixed gas limit, so the
transaction is mined and reverts on-chain; the script decodes the error by replaying the call at
that block. On testnet it saves `docs/evidence/phase2-raw-attack.json`. `pnpm abis` generates
`packages/chain/src/abis.ts` from the compiled contracts, and CI fails if it is stale.

### D-023: Slither and Foundry lint gates in CI

CI runs Slither 0.11.6 with `--fail-medium`. The four medium `incorrect-equality` findings are
false positives, annotated in the source, and the triage is in `docs/SLITHER.md`. Three Foundry
lints are disabled in `foundry.toml`, each with its reason recorded there.

### D-025: testnet tooling, found by rehearsing on a fork (2026-10-20)

- `forge script` ignores `ETH_RPC_URL`, so the deploy scripts now pass `--rpc-url` explicitly.
  Before this fix, `pnpm deploy:testnet` would have simulated on an in-memory chain instead of
  Base Sepolia.
- `Deploy.s.sol` and `SeedDemo.s.sol` write deployment files only when forge is really
  broadcasting (`vm.isContext(ScriptBroadcast | ScriptResume)`), so a dry run cannot record
  addresses that do not exist.
- Without `BASESCAN_API_KEY`, contracts are verified on Base Sepolia's Blockscout explorer, which
  needs no key. `pnpm verify:testnet` adds Basescan verification later. The `[etherscan]` and
  `base_sepolia` entries were removed from `foundry.toml`, so an empty key never breaks config
  loading.
- The raw-attack agent's gas money is sized from the live fee estimate (3x, plus an L1-fee
  margin) and the attack pins the same max fee, instead of a fixed 0.0001 ETH that failed on the
  fork.
- The raw-attack evidence records balance changes, not absolute balances: on Base Sepolia,
  `0x…dEaD` already holds other people's burned test USDC. A pass now also requires an attacker
  change and a vault change of 0.
- `pnpm testnet:check` (read-only readiness) and `pnpm testnet:rehearse` (the whole flow on an
  anvil fork of Base Sepolia, with real deployment files backed up and restored) were added. A
  rehearsal skips verification, `.env` updates and evidence files.

### D-024: stretch goal (`executeAction`) deferred

The handbook allows the allowlisted-actions stretch only "after every acceptance check in this
phase passes". The two Base Sepolia checks (deploy and verify, and the on-chain
`RecipientNotAllowed` hash) wait on testnet funding, so `executeAction` and `MockSwapRouter` are
not built yet.
