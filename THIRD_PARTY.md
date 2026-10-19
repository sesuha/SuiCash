# Third-party code, models and data

Every third-party dependency, tool, model and dataset SuiCash uses, with its licence (handbook
rule 8, rulebook section 8). Versions are the exact ones pinned in `pnpm-lock.yaml` or
installed by CI. Update this file in the same commit that adds or upgrades a dependency.

## Runtime dependencies (shipped in the web app)

| Package     | Version | Licence | Used for                    |
| ----------- | ------- | ------- | --------------------------- |
| `react`     | 19.3.1  | MIT     | UI                          |
| `react-dom` | 19.3.1  | MIT     | UI                          |
| `viem`      | 2.57.7  | MIT     | Chain client, account tools |

## Solidity libraries

| Library                                                                             | Version                    | Licence           | Used for                                                                                  |
| ----------------------------------------------------------------------------------- | -------------------------- | ----------------- | ----------------------------------------------------------------------------------------- |
| [`forge-std`](https://github.com/foundry-rs/forge-std)                              | v1.17.0 (commit `f3dae6e`) | MIT OR Apache-2.0 | Contract tests and deploy scripts (not deployed)                                          |
| [`@openzeppelin/contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts) | 5.6.1                      | MIT               | `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, `ERC20`, `ERC4626` (deployed) |

## Development dependencies (not shipped)

| Package                       | Version | Licence    |
| ----------------------------- | ------- | ---------- |
| `typescript`                  | 5.9.3   | Apache-2.0 |
| `vite`                        | 8.3.4   | MIT        |
| `@vitejs/plugin-react`        | 6.1.2   | MIT        |
| `vitest`                      | 5.0.5   | MIT        |
| `@playwright/test`            | 1.64.1  | Apache-2.0 |
| `eslint`                      | 10.13.0 | MIT        |
| `@eslint/js`                  | 10.0.1  | MIT        |
| `typescript-eslint`           | 8.71.2  | MIT        |
| `eslint-plugin-react-hooks`   | 7.1.1   | MIT        |
| `eslint-plugin-react-refresh` | 0.5.7   | MIT        |
| `globals`                     | 17.13.0 | MIT        |
| `prettier`                    | 3.9.10  | MIT        |
| `tsx`                         | 4.23.15 | MIT        |
| `@types/node`                 | 24.19.2 | MIT        |
| `@types/react`                | 19.3.0  | MIT        |
| `@types/react-dom`            | 19.3.0  | MIT        |

## Tools (used, not distributed)

| Tool                                           | Version | Licence           |
| ---------------------------------------------- | ------- | ----------------- |
| Foundry (forge, cast, anvil)                   | 1.8.5   | MIT OR Apache-2.0 |
| Solidity compiler (solc)                       | 0.8.37  | GPL-3.0           |
| Slither                                        | 0.11.6  | AGPL-3.0          |
| pnpm                                           | 12.14.0 | MIT               |
| GitHub Actions: `actions/checkout`             | v7.0.1  | MIT               |
| GitHub Actions: `actions/setup-node`           | v7.1.0  | MIT               |
| GitHub Actions: `pnpm/action-setup`            | v6.1.0  | MIT               |
| GitHub Actions: `foundry-rs/foundry-toolchain` | v1.9.1  | MIT OR Apache-2.0 |
| GitHub Actions: `actions/setup-python`         | v7.0.0  | MIT               |

Compiling with solc does not put its GPL licence on the compiled contracts. Slither is run as a
separate analysis tool and is not linked or distributed.

## Services

| Service                 | Use                             |
| ----------------------- | ------------------------------- |
| Base Sepolia public RPC | Chain reads and simulation      |
| Circle test USDC        | Test stablecoin on Base Sepolia |

## Models and data

None yet. The in-browser models (Phase 5) and training data (Phase 6) are recorded here and in
`docs/MODEL_CARD.md` when added.
