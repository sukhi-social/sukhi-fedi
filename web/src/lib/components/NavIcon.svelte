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
    | 'send'
    | 'plus'
    | 'repeat'
    | 'quote'
    | 'reply'
    | 'more'
    | 'pin'
    | 'trash'
    | 'flag';

  // filled: 押している状態を「かたち」でも示す(星・栞を塗りつぶす)。
  // 色だけに頼らない ── 淡い地の色は読み上げにも印刷にも残らないから。
  let { name, filled = false }: { name: IconName; filled?: boolean } = $props();
</script>

<svg
  class="nav-ico"
  viewBox="0 0 24 24"
  fill={filled ? 'currentColor' : 'none'}
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
  {:else if name === 'plus'}
    <path d="M12 5.5v13M5.5 12h13" />
  {:else if name === 'repeat'}
    <!-- ブースト。角の丸い輪をぐるりと回る矢印 ── 同じものを繰り返す、の形。 -->
    <path d="M4 11V9.5A3.5 3.5 0 0 1 7.5 6H20" />
    <path d="M17 3l3 3-3 3" />
    <path d="M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H4" />
    <path d="M7 21l-3-3 3-3" />
  {:else if name === 'quote'}
    <!-- 引用。ことばの吹き出し。 -->
    <path d="M4.5 5.5h15v10h-9l-4.5 3.5v-3.5h-1.5Z" />
  {:else if name === 'reply'}
    <path d="M9.5 8 5 12.5 9.5 17" />
    <path d="M5 12.5h8.5a5.5 5.5 0 0 1 5.5 5.5" />
  {:else if name === 'more'}
    <circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none" />
    <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
    <circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none" />
  {:else if name === 'pin'}
    <path d="M9 4.5h6l-1 5 2.5 2.5v1.5h-9V12L10 9.5Z" />
    <path d="M12 13.5V20" />
  {:else if name === 'trash'}
    <path d="M5 7h14M10 7V5h4v2M7 7l1 12.5h8L17 7" />
  {:else if name === 'flag'}
    <path d="M6 20.5V4.5" />
    <path d="M6 5h11l-2.2 3.5L17 12H6" />
  {/if}
</svg>

<style>
  .nav-ico {
    width: var(--nav-ico-size, 1.6em);
    height: var(--nav-ico-size, 1.6em);
    flex: none;
    display: block;
  }
</style>
