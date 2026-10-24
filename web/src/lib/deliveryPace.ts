// 配信の時系列を、人が目で追える速さで進める決めごと。
//
// サーバの答えは、速ければ一度の問い合わせで「受付」から「完了」まで
// 飛ぶ。そのまま出すと、段が一瞬で流れて、何が起きたのか読めない。
// だから見せる側は、段を 1 つずつ、すこし間をあけて進める。飛ばさない、
// 戻らない。完了したあとも、すこしそのまま置いてから、そっと消す。

export const STEPS = ['received', 'signing', 'queued', 'sending', 'done'] as const;
export type Step = (typeof STEPS)[number];

export type Shown = { at: number; percent: number | null };

// 次の段へ進むまでの間(ミリ秒)。
export const STEP_MS = 300;
// % が動くときの間。実際の値へ一度で飛ぶので、段と同じ。
export const PERCENT_MS = 300;
// 完了を見せてから、消すまで。
export const LINGER_MS = 10_000;

export function target(
  p: { stage: Step; percent: number | null } | null | undefined
): Shown | null {
  return p ? { at: STEPS.indexOf(p.stage), percent: p.percent } : null;
}

// いま見せているものから、目標へ向けて「ひと動き」だけ進める。戻らない。
//
//   ・段が遅れていれば 1 段進む。ただし「配信中」の段は、% が 100 になって
//     から次へ(100% を見せずに完了へ行かない)。
//   ・「配信中」に入るとき、先に完了まで行く目標なら、入ってすぐ 100%。
//     目標がここなら、入ってすぐ実際の値。
//   ・段が着いていれば、% は 10 刻みを一つずつ上るのではなく、実際の値へ
//     一度で飛ぶ。
export function stepToward(shown: Shown, goal: Shown): Shown {
  const SENDING = STEPS.indexOf('sending');

  if (shown.at < goal.at) {
    if (shown.at === SENDING && (shown.percent ?? 0) < 100) {
      return { at: shown.at, percent: 100 };
    }
    const at = shown.at + 1;
    if (at === SENDING) return { at, percent: goal.at > SENDING ? 100 : (goal.percent ?? 0) };
    return { at, percent: STEPS[at] === 'done' ? 100 : null };
  }
  if (shown.at === goal.at && shown.percent != null && goal.percent != null) {
    if (shown.percent < goal.percent) return { at: shown.at, percent: goal.percent };
  }
  return shown;
}

export function arrived(shown: Shown, goal: Shown): boolean {
  return shown.at >= goal.at && (shown.percent ?? 0) >= (goal.percent ?? 0);
}

// 次のひと動きまでの間。段が動くか、% が動くか。
export function delayFor(shown: Shown, goal: Shown): number {
  return shown.at < goal.at ? STEP_MS : PERCENT_MS;
}
