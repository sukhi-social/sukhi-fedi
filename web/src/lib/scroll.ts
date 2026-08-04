// 会話の面のスクロールの決めごと。ブラウザに触らない部分だけ。
//
// 一本の規則に畳める:
//
//   **下にいるときだけ、ついていく。**
//
// 上に遡っている人を引っぱらない ── 読んでいる最中に足元をさらわれるのは、
// 新しい一通を見逃すことより困る。かわりに「新しいメッセージ」とだけ置いて、
// 行くかどうかは、その人が決める。
//
// (Slack も Telegram も Discord も同じ形に着く。逆 ── 一通来るたび下へ
//  引っぱる ── は、遡って読むことを不可能にする。)

/**
 * 「いちばん下にいる」と見なす余裕。
 *
 * 0 にすると、指を離したあとの慣性やアドレスバーの伸び縮みで数 px ずれた
 * だけで「下にいない」ことになる。人の感覚では、あと少しで底なら底。
 */
export const BOTTOM_SLACK_PX = 120;

/** いま、いちばん下にいるか。 */
export function atBottom(
  scrollY: number,
  viewportHeight: number,
  documentHeight: number,
  slack = BOTTOM_SLACK_PX
): boolean {
  return documentHeight - (scrollY + viewportHeight) <= slack;
}

/**
 * 新しい一通が来た。どうするか。
 *
 * - `follow`  下にいた。そのままついていく(その人はいま、待っている)
 * - `mark`    上に遡っていた。動かさずに、来たことだけ知らせる
 * - `nothing` 増えていない。何もしない
 *
 * 自分が送ったぶんは、遡っていても必ずついていく ── 送信は「いま、ここに
 * 居る」という一番はっきりした合図で、自分の言葉が画面の外に出るのは、
 * ただ壊れて見える。
 */
export type Arrival = 'follow' | 'mark' | 'nothing';

export function onArrival(opts: {
  added: number;
  wasAtBottom: boolean;
  mine?: boolean;
}): Arrival {
  if (opts.added <= 0) return 'nothing';
  if (opts.mine) return 'follow';
  return opts.wasAtBottom ? 'follow' : 'mark';
}

/**
 * 古いぶんを上に足したあと、読んでいた場所に戻すための座標。
 *
 * ブラウザには位置を保つ仕組み(scroll anchoring)があるけれど、**いちばん
 * 上にいるときは効かない** ── そして「もっと読む」は上にあるので、押すには
 * 上にいるしかない。つまりここでは、あの仕組みは構造的に一度も働かない。
 * (Safari と iOS にはそもそも無い。)
 *
 * なので自分で覚えて戻す。覚えるのは「下からの距離」── 上に足されても
 * 変わらない唯一の量。
 */
export function keepPlaceAfterPrepend(
  distanceFromBottomBefore: number,
  documentHeightAfter: number
): number {
  return Math.max(0, documentHeightAfter - distanceFromBottomBefore);
}

/** 覚えておく側。`keepPlaceAfterPrepend` と対で使う。 */
export function distanceFromBottom(scrollY: number, documentHeight: number): number {
  return documentHeight - scrollY;
}
