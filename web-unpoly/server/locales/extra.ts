// この再実装で足したことば。sukhi-web-next の辞書(ja.ts / ko.ts)に無いものだけ。
// 「四半刻」「ポツポツ」「ここまで」── 急かさない、のためのことば。

export const jaExtra = {
  'end.here': 'ここまで、です。',
  'login.again': 'しばらく経ったので、もういちど入ってください。',
  'error.notFound': 'その頁は、見つかりませんでした。',
  'error.refused': 'その道は、ここからは通れません。',
  'compose.queuedHint': '送ると、{when}後に上がります。そのあいだ、見直したり、とりやめたりできます。',
  'compose.queued': '投稿は{when}後に上がります。それまで、見直せます。',
  'compose.posted': 'いま、上がりました。',
  'compose.holding': 'お預かりしているもの',
  'compose.holdingUntil': '{when}に上がります',
  'compose.withdraw': 'とりやめる',
  'compose.withdrawn': 'とりやめました。',
  'compose.withdrawFailed': 'とりやめられませんでした。すこしあとで、もう一度どうぞ。',
  'notif.holdNote': '反応は、一刻ほど置いてから、ポツポツお届けしています。',
  'notif.holdingMore': 'まだ、道の途中のものがあります。'
} as const;

export const koExtra: Record<keyof typeof jaExtra, string> = {
  'end.here': '여기까지예요.',
  'login.again': '시간이 좀 지나서, 다시 한 번 들어와 주세요.',
  'error.notFound': '그 페이지는 찾을 수 없었어요.',
  'error.refused': '그 길은 여기서는 지날 수 없어요.',
  'compose.queuedHint': '보내면 {when} 뒤에 올라가요. 그동안 다시 읽어 보거나 거둘 수 있어요.',
  'compose.queued': '글은 {when} 뒤에 올라가요. 그때까지 다시 읽어 볼 수 있어요.',
  'compose.posted': '방금 올라갔어요.',
  'compose.holding': '맡아 두고 있는 글',
  'compose.holdingUntil': '{when}에 올라가요',
  'compose.withdraw': '거두기',
  'compose.withdrawn': '거두었어요.',
  'compose.withdrawFailed': '거두지 못했어요. 잠시 뒤에 다시 해 주세요.',
  'notif.holdNote': '반응은 한 시간쯤 두었다가, 하나둘 전해 드리고 있어요.',
  'notif.holdingMore': '아직 오는 길에 있는 것이 있어요.'
};
