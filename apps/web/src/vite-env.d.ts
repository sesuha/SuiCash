/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_CHAIN_ID?: string;
  readonly VITE_RPC_URL?: string;
  readonly VITE_BUNDLER_URL?: string;
  readonly VITE_PAYMASTER_URL?: string;
  readonly VITE_USDC_ADDRESS?: string;
  readonly VITE_VAULT_FACTORY_ADDRESS?: string;
  readonly VITE_SAVINGS_POOL_ADDRESS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
