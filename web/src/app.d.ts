declare global {
  // vite.config.ts の define が、リポジトリの VERSION を差し込む。
  const __APP_VERSION__: string;

  namespace App {
    // lib/ux/overlay.svelte.ts が、窓を開いたときに履歴へ足す印。
    interface PageState {
      ux?: number;
    }
  }
}

export {};
