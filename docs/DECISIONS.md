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
