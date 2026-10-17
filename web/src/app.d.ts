declare global {
  namespace App {
    // lib/ux/overlay.svelte.ts が、窓を開いたときに履歴へ足す印。
    interface PageState {
      ux?: number;
    }
  }
}

export {};
