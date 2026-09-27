// 「もっと読む」の共通の作法。
//
// 次のページを裏で先読みしておいて、押した瞬間に静かな間だけ置いてから
// 差し込む ── どの一覧でも同じ手触りになるように、一箇所にまとめる。
// (タイムラインに inline で育てた挙動を、そのまま型にしたもの。timeline は
//  接続待ち/自動再試行が絡むので当面は自前のまま。)
//
// 使う側は items / hasMore / revealing を読み、reset()・more() を呼ぶだけ。
// 取得の失敗は呼び手に投げるので、unauthorized やエラー表示は各ページの
// 方針で拾う。一覧から1件外すなどの楽観更新は items への代入で。

export type Page<T> = { items: T[]; nextMaxId: string | null };

// 一瞬で湧くと目が追えず落ち着かないので、短い静かな「間」を置いてから
// 差し込む ── 認知負荷を上げない程度のディレイ。
const REVEAL_DELAY_MS = 280;
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function createPager<T>(fetchPage: (maxId: string | null) => Promise<Page<T>>) {
  let items = $state<T[]>([]);
  let nextMaxId = $state<string | null>(null);
  let prefetched = $state<Page<T> | null>(null);
  let revealing = $state(false);

  // 次のページを裏で取って控える。空なら終わりと分かるので nextMaxId を
  // 畳む(= ボタンが消える)。cursor が古くなっていたら(リセットなどで先へ
  // 進んだ)結果は捨てる。
  async function prefetchNext(cursor: string) {
    try {
      const page = await fetchPage(cursor);
      if (cursor !== nextMaxId) return;
      if (page.items.length === 0) {
        nextMaxId = null;
        prefetched = null;
      } else {
        prefetched = { items: page.items, nextMaxId: page.nextMaxId };
      }
    } catch {
      if (cursor === nextMaxId) prefetched = null;
    }
  }

  // すでに取れている一枚を、そのまま種にする。`load` が先読みした最初の
  // ページを頁へ渡すとき(先読みが効いた遷移では、ここに来る時点で取得は
  // 済んでいる)と、reset の後始末とで同じ道を通る。
  function hydrate(page: Page<T>): void {
    items = page.items;
    // 0 件が返ったら、Link が次を匂わせていても終わり扱いにする。
    nextMaxId = page.items.length === 0 ? null : page.nextMaxId;
    if (nextMaxId) void prefetchNext(nextMaxId);
  }

  return {
    get items(): T[] {
      return items;
    },
    set items(v: T[]) {
      items = v;
    },
    get hasMore(): boolean {
      return nextMaxId !== null;
    },
    get revealing(): boolean {
      return revealing;
    },

    hydrate,

    // 頭から読み直す。失敗は呼び手に投げる。
    async reset(): Promise<void> {
      items = [];
      nextMaxId = null;
      prefetched = null;
      hydrate(await fetchPage(null));
    },

    // 「もっと読む」。先読みが手元にあれば、行き先を先へ進めて、その次の
    // 取得を裏で走らせ、静かな間を置いてから差す。間に合っていなければ
    // (押すのが早すぎた等)その場で取りに行く従来どおりの保険。
    async more(): Promise<void> {
      if (revealing) return;
      if (!prefetched) {
        const page = await fetchPage(nextMaxId);
        items = [...items, ...page.items];
        nextMaxId = page.items.length === 0 ? null : page.nextMaxId;
        if (nextMaxId) void prefetchNext(nextMaxId);
        return;
      }
      const batch = prefetched;
      prefetched = null;
      nextMaxId = batch.nextMaxId;
      if (nextMaxId) void prefetchNext(nextMaxId);
      revealing = true;
      await sleep(REVEAL_DELAY_MS);
      items = [...items, ...batch.items];
      revealing = false;
    }
  };
}
