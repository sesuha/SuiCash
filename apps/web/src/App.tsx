import { useEffect, useState } from "react";
import { createReadClient, type ChainConfig } from "@suicash/chain";
import { TIERS, TIER_DESCRIPTIONS } from "@suicash/core";
import { loadConfig, rpcHost } from "./lib/config.ts";

const configResult = loadConfig(import.meta.env);

type ChainStatus =
  | { state: "connecting" }
  | { state: "connected"; blockNumber: bigint }
  | { state: "unreachable"; error: string };

function useChainStatus(config: ChainConfig): ChainStatus {
  const [status, setStatus] = useState<ChainStatus>({ state: "connecting" });

  useEffect(() => {
    const client = createReadClient(config);
    let cancelled = false;
    const poll = async () => {
      try {
        const blockNumber = await client.getBlockNumber({ cacheTime: 0 });
        if (!cancelled) setStatus({ state: "connected", blockNumber });
      } catch (error) {
        if (!cancelled) {
          setStatus({
            state: "unreachable",
            error:
              error instanceof Error
                ? (error.message.split("\n")[0] ?? error.message)
                : String(error),
          });
        }
      }
    };
    void poll();
    const timer = setInterval(() => void poll(), 4000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [config]);

  return status;
}

function NetworkPanel({ config }: { config: ChainConfig }) {
  const status = useChainStatus(config);
  return (
    <dl className="facts" aria-label="Network">
      <dt>Network</dt>
      <dd>
        {config.chain.name} <span className="muted">(chain {config.chain.id})</span>
      </dd>
      <dt>RPC</dt>
      <dd className="mono">{rpcHost(config.rpcUrl)}</dd>
      <dt>Status</dt>
      <dd data-testid="chain-status" data-state={status.state}>
        {status.state === "connecting" && "Connecting…"}
        {status.state === "connected" && (
          <>
            Connected, latest block <span className="mono">{status.blockNumber.toString()}</span>
          </>
        )}
        {status.state === "unreachable" && <>Unreachable: {status.error}</>}
      </dd>
    </dl>
  );
}

export function App() {
  return (
    <main className="page">
      <header>
        <h1>SuiCash</h1>
        <p className="pitch">
          An AI that can move your money, but can't be talked into stealing it.
        </p>
      </header>

      <section className="card">
        <h2>Environment</h2>
        {configResult.ok ? (
          <NetworkPanel config={configResult.config} />
        ) : (
          <p role="alert" data-testid="config-error">
            Configuration error: {configResult.error}. Copy <code>.env.example</code> to{" "}
            <code>.env</code>, or run <code>pnpm dev</code> for a local chain.
          </p>
        )}
      </section>

      <section className="card">
        <h2>Permission tiers</h2>
        <ul className="tiers">
          {TIERS.map((tier) => (
            <li key={tier}>
              <strong>{tier}</strong> {TIER_DESCRIPTIONS[tier]}
            </li>
          ))}
        </ul>
      </section>

      <footer className="muted">Phase 1 skeleton · testnet only</footer>
    </main>
  );
}
