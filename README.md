# SuiCash

**An AI that can move your money, but can't be talked into stealing it.**

SuiCash is an AI wallet agent for FinTechathon 2026, **Topic F**. It manages a stablecoin
treasury and executes on-chain actions (payments, batch payouts, savings and treasury rules)
within limits that the owner sets and the blockchain enforces. Three independent layers stand
between the model and the money: a least-privilege agent, a deterministic policy engine, and an
on-chain `PolicyVault`.

> **Status: Phase 2 of 10 (smart contracts).** `PolicyVault`, `VaultFactory` and `SavingsPool`
> are built and pass 113 tests: unit, fuzz at 10,000 runs, and 8 invariants under a hostile
> agent. Slither reports no high or medium findings. The Base Sepolia deployment and the
> on-chain attack evidence wait on testnet funding. The policy engine, the in-browser model and
> the app arrive in later phases. **Testnet only:** never use a mainnet key or a seed phrase with
> this project.

## Prerequisites

| Tool                                                               | Version               | Needed for               |
| ------------------------------------------------------------------ | --------------------- | ------------------------ |
| [Node.js](https://nodejs.org)                                      | 22.12+ (24 LTS in CI) | Everything               |
| [pnpm](https://pnpm.io)                                            | 12.14.0 (pinned)      | Everything               |
| [Foundry](https://book.getfoundry.sh/getting-started/installation) | 1.8.5                 | Contracts, anvil         |
| Git, [GitHub CLI](https://cli.github.com)                          | any recent            | Repository               |
| Chrome or Edge with WebGPU (`chrome://gpu`)                        | 113+                  | In-browser model         |
| Python                                                             | 3.11                  | Model training (Phase 6) |
| [Slither](https://github.com/crytic/slither)                       | 0.11+                 | Contract analysis        |

Install Foundry with `curl -L https://foundry.paradigm.xyz | bash`, then `foundryup`. On
Windows, run those two commands in Git Bash.

## Quick start (local, no keys or testnet funds needed)

```sh
pnpm install
pnpm dev          # or ./scripts/dev.sh
```

`pnpm dev` starts anvil on `127.0.0.1:8545`, deploys the contracts, seeds demo data (from
Phase 2), writes `.env.development.local` for the local chain, and serves the app at
<http://localhost:5173>. Ctrl+C stops everything. ERC-4337 features (bundler, paymaster) run on
the testnet only.

## Testnet setup (Base Sepolia)

1. `cp .env.example .env`, then fill it in. `.env` is gitignored.
2. Create a deployer key: `pnpm new-deployer-key`. This writes `DEPLOYER_PRIVATE_KEY` to `.env`
   and prints only the address. `cast wallet new` also works.
3. Fund that address with Base Sepolia ETH (the Coinbase Developer Platform faucet, or another
   Base Sepolia faucet), and with test USDC from <https://faucet.circle.com>.
4. Create a [ZeroDev](https://dashboard.zerodev.app) (or Pimlico) project for Base Sepolia, and
   copy its bundler and paymaster URLs into `VITE_BUNDLER_URL` and `VITE_PAYMASTER_URL`.
5. Set `VITE_RPC_URL`. The public `https://sepolia.base.org` works for light use; a free Alchemy
   (or similar) endpoint is more reliable.
6. Set `BASESCAN_API_KEY` (an Etherscan V2 key) for source verification. Then run
   `pnpm deploy:testnet`. It refuses to run unless the RPC reports chain ID 84532. It deploys and
   verifies the contracts, seeds a demo vault owned by the deployer, and writes
   `contracts/deployments/84532.json` and `84532-demo.json`. With only faucet USDC, set a smaller
   `SEED_BUFFER` and `SEED_FUND` in `.env` (see `.env.example`).
7. Run `pnpm raw-attack testnet`. A throwaway agent key sends a raw `executeTransfer` to an
   attacker address. It reverts on-chain with `RecipientNotAllowed`, and the transaction hashes
   are saved to `docs/evidence/phase2-raw-attack.json`.

## Commands

| Command                            | What it does                                                                                                |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `pnpm dev`                         | Local chain, deployment, and the app's dev server                                                           |
| `pnpm build`                       | Builds every package, the web app and the contracts                                                         |
| `pnpm test`                        | Unit tests (Vitest)                                                                                         |
| `pnpm test:contracts`              | Contract unit, fuzz and invariant tests (Foundry)                                                           |
| `pnpm test:e2e`                    | End-to-end tests (Playwright; run `pnpm --filter @suicash/web exec playwright install chromium` once first) |
| `pnpm redteam`                     | Red-team suite (cases arrive in Phase 8)                                                                    |
| `pnpm eval`                        | Task-completion suite (tasks arrive in Phase 9)                                                             |
| `pnpm deploy:local`                | Deploys the contracts to a running anvil node                                                               |
| `pnpm deploy:testnet`              | Deploys to Base Sepolia and verifies the source on Basescan                                                 |
| `pnpm raw-attack <local\|testnet>` | Sends a raw malicious transfer from the agent key; it must revert with `RecipientNotAllowed`                |
| `pnpm abis`                        | Regenerates the typed ABIs in `packages/chain` from the compiled contracts                                  |
| `pnpm evidence`                    | Generates `docs/EXECUTION_EVIDENCE.md` (Phase 9)                                                            |
| `pnpm lint`                        | ESLint, Prettier and `forge fmt` checks                                                                     |
| `pnpm typecheck`                   | TypeScript, strict mode                                                                                     |

CI (`.github/workflows/ci.yml`) runs on every push: lint, typecheck, the contract tests, an ABI
freshness check, Slither (failing on any medium or high finding), the unit tests, the red-team
suite and the production build. A failing red-team case fails the build. The Slither triage is
in [`docs/SLITHER.md`](docs/SLITHER.md), and gas costs are in
[`docs/GAS_REPORT.md`](docs/GAS_REPORT.md).

## Repository layout

```
contracts/         Foundry project: src/, test/, script/, deployments/
packages/core/     Shared TypeScript: schemas, policy engine, tool definitions, fallback parser
packages/chain/    viem clients, ABIs, account and session helpers
apps/web/          Vite + React app; src/worker/ will hold the model worker
ml/                Python: data generation, fine-tuning, evaluation, conversion
redteam/           Attack cases (JSON) and the runner
eval/              Task-completion cases and the runner
scripts/           dev, deploy, evidence, key generation
docs/              Technical document, security self-assessment, evidence, threat model,
                   decisions, model card
```

Where the build differs from the build handbook, the reason is recorded in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Licence

MIT; see [`LICENSE`](LICENSE). Third-party code, tools and their licences are listed in
[`THIRD_PARTY.md`](THIRD_PARTY.md).
