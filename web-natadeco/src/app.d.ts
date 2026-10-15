// SvelteKit の型の穴埋め。`locals` はサーバの hooks が請求ごとに置くもの。
declare global {
  namespace App {
    interface Locals {
      // Accept-Language から決めた、この一枚を描く言語。
      lang: 'ja' | 'ko';
      // どの玄関から来た請求か(natadeco.com か travel.natadeco.com か)。
      site: import('#lib/site.js').Site;
    }
  }
}

export {};
