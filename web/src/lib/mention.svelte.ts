// メンション補完の状態。境目の判定そのものは mention.ts(純粋)。
//
// **相手のサーバには問い合わせない。** `resolve` を付けると WebFinger で
// 遠くまで探しに行くが、それは「この人を初めてフォローする」ときの手続きで、
// 一文字打つたびにやることではない。ここは、この星がもう知っている人だけ。

import { searchAll, type Account } from './api';
import { fragmentAt, type Fragment } from './mention';

/**
 * 手が止まってから探しに行く ── 一文字ごとに投げると、打っているあいだ
 * じゅうサーバを叩くことになる。打ち進んで語が変わったら、returning した
 * 古い結果は捨てる(seq)。
 */
export function createMentions(delayMs = 220) {
  let items = $state<Account[]>([]);
  let active = $state(0);
  let fragment = $state<Fragment | null>(null);

  let timer: ReturnType<typeof setTimeout> | null = null;
  let seq = 0;

  function close() {
    if (timer !== null) clearTimeout(timer);
    timer = null;
    seq += 1;
    items = [];
    active = 0;
    fragment = null;
  }

  function look(text: string, caret: number) {
    const f = fragmentAt(text, caret);
    // `@` を打っただけでは、まだ探しに行かない(全員が返ってくるので)。
    if (!f || f.query.length === 0) {
      close();
      return;
    }
    fragment = f;
    if (timer !== null) clearTimeout(timer);
    const mine = ++seq;
    timer = setTimeout(async () => {
      try {
        const r = await searchAll(f.query, { type: 'accounts', limit: 6 });
        if (mine !== seq) return;
        items = r.accounts;
        active = 0;
      } catch {
        if (mine === seq) items = [];
      }
    }, delayMs);
  }

  return {
    get items() {
      return items;
    },
    get active() {
      return active;
    },
    get fragment() {
      return fragment;
    },
    get open() {
      return items.length > 0 && fragment !== null;
    },
    move(delta: number) {
      if (items.length === 0) return;
      active = (active + delta + items.length) % items.length;
    },
    look,
    close
  };
}
