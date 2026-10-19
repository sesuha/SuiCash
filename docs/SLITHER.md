# Slither results

Static analysis of `contracts/src/` with Slither 0.11.6 (102 detectors), using the filters in
`contracts/slither.config.json` (tests, scripts and dependencies excluded). CI runs
`slither . --fail-medium`, so any new medium or high finding fails the build.

```sh
cd contracts
slither .            # or, on Windows: py -3.11 -m slither .
```

## Summary (2026-10-19)

| Impact        | Count | Status                                      |
| ------------- | ----- | ------------------------------------------- |
| High          | 0     | n/a                                         |
| Medium        | 0     | 4 reviewed as false positives and annotated |
| Low           | 16    | Reviewed, by design                         |
| Informational | 1     | Reviewed, false positive                    |

## Medium: `incorrect-equality` (4, false positives, annotated in the source)

Slither flags strict equality on values derived from `block.timestamp`, because exact timestamp
matches are fragile. None of these compares a timestamp with `==`:

| Location                               | Expression                  | Why it is correct                                                                                                                                                                                |
| -------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `PolicyVault._spentToday`              | `s.day == _today()`         | Compares UTC-day buckets (`timestamp / 1 days`). "Same day" is exactly equality. A validator can skew time by seconds, which can at most move the reset of a 24-hour allowance by those seconds. |
| `PolicyVault.executeLimitIncrease`     | `pending.eta == 0`          | `0` is the "nothing queued" sentinel. The timelock itself is checked with `<`.                                                                                                                   |
| `PolicyVault.executeSavingsPoolChange` | `pending.eta == 0`          | Same sentinel.                                                                                                                                                                                   |
| `PolicyVault.getRequest`               | `request.status == Pending` | An enum comparison. The expiry is checked with `>`.                                                                                                                                              |

Each line carries `// slither-disable-next-line incorrect-equality` with the reason beside it.

## Low: `timestamp` (15, by design)

Sessions (`agentValidUntil`), recipient activation (`activeFrom`), request expiry (72 hours), the
24-hour limit timelock and the daily cap are time rules by definition (handbook 2.2-2.4). Validators
can move `block.timestamp` by a few seconds; none of these limits is meaningful at that scale.

## Low: `missing-zero-check` (1, intentional)

`VaultFactory.constructor(savingsPool_)` accepts the zero address on purpose: a vault can run
without a savings pool, and the owner can set one later (`PolicyVault.setSavingsPool`).

## Informational: `too-many-digits` (1, false positive)

`VaultFactory.predictVault` hashes `type(PolicyVault).creationCode`. Slither treats the bytecode
as a long literal. It is the standard CREATE2 address formula, checked by
`testFuzz_PredictVault_MatchesCreate`.

## Foundry lint

`forge lint src` reports one item: `missing-zero-check` on `PolicyVault.setGuardian`, where zero
means "no guardian" (tested in `test_SetGuardian_RejectsAgentAndSelf`). Three lints are disabled
in `foundry.toml` with the reason recorded there: `block-timestamp`, `non-reentrant-not-first`
(the handbook orders `whenNotPaused` before `nonReentrant`; the pause check makes no external
call) and `require-revert-in-loop` (a batch must revert as a whole). The six `unsafe-typecast`
sites are annotated in the source with why each cast cannot truncate.
