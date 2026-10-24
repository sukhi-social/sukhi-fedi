// 配信の時系列を、人が目で追える速さで進める決めごと。
//
// サーバの答えは、速ければ一度の問い合わせで「受付」から「完了」まで
// 飛ぶ。そのまま出すと、段が一瞬で流れて、何が起きたのか読めない。
// だから見せる側は、段を 1 つずつ、すこし間をあけて進める。飛ばさない、
// 戻らない。完了したあとも、すこしそのまま置いてから、そっと消す。

export const STEPS = ['received', 'signing', 'queued', 'sending', 'done'] as const;
export type Step = (typeof STEPS)[number];

export type Shown = { at: number; percent: number | null };

// 次の段へ進むまでの間(ミリ秒)。1 段ずつ読める長さ。
export const STEP_MS = 800;
// % が動くときの 1 刻みの間。段より少し短く。
export const PERCENT_MS = 500;
// 完了を見せてから、消すまで。
export const LINGER_MS = 1600;

export function target(
  p: { stage: Step; percent: number | null } | null | undefined
): Shown | null {
  return p ? { at: STEPS.indexOf(p.stage), percent: p.percent } : null;
}

// いま見せているものから、目標へ向けて「ひと動き」だけ進める。
// 段が遅れていれば 1 段、段が着いていれば % を 1 刻み(10)。戻らない。
export function stepToward(shown: Shown, goal: Shown): Shown {
  if (shown.at < goal.at) {
    const at = shown.at + 1;
    return { at, percent: STEPS[at] === 'sending' ? 0 : STEPS[at] === 'done' ? 100 : null };
  }
  if (shown.at === goal.at && shown.percent != null && goal.percent != null) {
    if (shown.percent < goal.percent) return { at: shown.at, percent: shown.percent + 10 };
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
