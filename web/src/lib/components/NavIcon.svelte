<script lang="ts">
  // ナビの線画アイコン。ぜんぶ currentColor の輪郭線で、色は持たない
  // ── chip の文字色にそのまま従う。中身の彩り(Twemoji のリアクション)
  // とは別の言語で、縁(chrome)は墨のまま、というのがここの約束。
  // かたちは「これは何のためか」が一目でわかる素直なものだけ。
  export type IconName =
    | 'home'
    | 'bell'
    | 'mail'
    | 'search'
    | 'bookmark'
    | 'star'
    | 'list'
    | 'library'
    | 'gear'
    | 'compose'
    | 'logout'
    | 'user'
    | 'back'
    | 'image'
    | 'send';

  let { name }: { name: IconName } = $props();
</script>

<svg
  class="nav-ico"
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="1.7"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"
  focusable="false"
>
  {#if name === 'back'}
    <path d="M14.5 5 8 12l6.5 7" />
  {:else if name === 'image'}
    <rect x="3.5" y="5" width="17" height="14" rx="2" />
    <circle cx="8.5" cy="10" r="1.4" />
    <path d="M4 17l4.5-4.5L12 16l3-3 5 5" />
  {:else if name === 'send'}
    <!-- 紙飛行機。折り目の線を一本入れると、ただの三角に見えない。 -->
    <path d="M20 4 3.5 11l6.5 2.2L20 4Z" />
    <path d="M20 4l-7 16-2.9-6.9L20 4Z" />
  {:else if name === 'home'}
    <path d="M3.5 11.5 12 4l8.5 7.5" />
    <path d="M6 10v9.5h12V10" />
  {:else if name === 'bell'}
    <path d="M6 17c1.2-1.5 1.5-3.5 1.5-6a4.5 4.5 0 0 1 9 0c0 2.5.3 4.5 1.5 6Z" />
    <path d="M10 20a2 2 0 0 0 4 0" />
  {:else if name === 'mail'}
    <rect x="3.5" y="6" width="17" height="12" rx="1.5" />
    <path d="M4 7.5 12 13l8-5.5" />
  {:else if name === 'search'}
    <circle cx="11" cy="11" r="6.5" />
    <path d="M16 16 20.5 20.5" />
  {:else if name === 'bookmark'}
    <path d="M7 4.5h10v15l-5-4-5 4Z" />
  {:else if name === 'star'}
    <path d="M12 4 14.3 9.2 20 9.8 15.7 13.7 17 19.3 12 16.4 7 19.3 8.3 13.7 4 9.8 9.7 9.2Z" />
  {:else if name === 'list'}
    <path d="M8.5 7H20M8.5 12H20M8.5 17H20" />
    <circle cx="4.6" cy="7" r="0.9" />
    <circle cx="4.6" cy="12" r="0.9" />
    <circle cx="4.6" cy="17" r="0.9" />
  {:else if name === 'library'}
    <!-- 棚をまとめる入口。中身(栞・お気に入り・リスト)を仕舞う容れ物 -->
    <path d="M3.5 18.5V7.5H9l2 2h9.5v9Z" />
  {:else if name === 'user'}
    <!-- アバターが無いときの代わり。頭と肩。 -->
    <circle cx="12" cy="8.5" r="3.5" />
    <path d="M5.5 19.5a6.5 6.5 0 0 1 13 0" />
  {:else if name === 'gear'}
    <!-- 環＋短い歯。放射線にすると太陽に見えるので、歯は環のすぐ外に
         短く太く置いて、歯車だと分かるようにする。 -->
    <circle cx="12" cy="12" r="4.4" />
    <path
      d="M16.4 12 18.4 12M15.1 15.1 16.5 16.5M12 16.4 12 18.4M8.9 15.1 7.5 16.5M7.6 12 5.6 12M8.9 8.9 7.5 7.5M12 7.6 12 5.6M15.1 8.9 16.5 7.5"
    />
  {:else if name === 'compose'}
    <path d="M14.5 5.5 18.5 9.5 9 19l-4.2 1.2L6 16Z" />
    <path d="M13.5 6.5 17.5 10.5" />
  {:else if name === 'logout'}
    <path d="M14 4H6v16h8" />
    <path d="M10 12h10M16.5 8.5 20 12l-3.5 3.5" />
  {/if}
</svg>
