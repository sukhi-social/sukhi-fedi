// SPDX-License-Identifier: AGPL-3.0-or-later
// メンテナンスの頁(server/maintenance.ts)のことば。
//
// 意図: 止まっている間に来た人が、「壊れた」ではなく「いま整えています」と受け取れること。
// 読み手の問題(仮説): 「落ちた? 消えた? 自分の投稿は? いつ戻る?」
// → 起きていること、預かりものは無事なこと、いつ戻りそうか(わからなければ、わからないと)の順に言う。
// 英語の声は docs/ENGLISH_VOICE.md。時刻は出さない(「半刻ほど」のようにゆるく)。

export const jaMaintenance = {
  'maint.title': 'メンテナンス中です',
  'maint.lead': 'いま、サーバーを整えています。終わるまで、書くことや押すことはお休みです。',
  'maint.kept': 'お預かりしているものは、このまま守ります。',
  'maint.why.update': '新しい版に入れ替えています。',
  'maint.why.backup': 'バックアップを取っています。',
  'maint.why.migration': 'データの置き場所を引っ越しています。',
  'maint.why.repair': '不具合を直しています。',
  'maint.eta': '{when}で戻る見込みです。延びることもあります。',
  'maint.etaLong': 'すこし長くかかる見込みです。',
  'maint.etaUnknown': '戻る時間は、まだ決まっていません。',
  'maint.back': '終わったら、この頁をひらきなおしてください。',
  'maint.readHead': '止まる前の、みんなの投稿',
  'maint.readNote': '読むだけです。ここからは、返信も、お気に入りもできません。',
  'maint.cw': '見たいときだけ、開く',
  'maint.about': 'このサーバーについて'
};

export const koMaintenance: Record<keyof typeof jaMaintenance, string> = {
  'maint.title': '점검 중입니다',
  'maint.lead': '지금 서버를 정돈하고 있어요. 끝날 때까지 글쓰기와 반응은 잠시 쉽니다.',
  'maint.kept': '맡겨 주신 것은 그대로 잘 지키고 있어요.',
  'maint.why.update': '새 버전으로 바꾸고 있어요.',
  'maint.why.backup': '백업을 만들고 있어요.',
  'maint.why.migration': '데이터를 새 자리로 옮기고 있어요.',
  'maint.why.repair': '문제를 고치고 있어요.',
  'maint.eta': '{when} 뒤에 돌아올 예정이에요. 늦어질 수도 있어요.',
  'maint.etaLong': '조금 오래 걸릴 것 같아요.',
  'maint.etaUnknown': '언제 돌아올지는 아직 정해지지 않았어요.',
  'maint.back': '끝나면 이 페이지를 다시 열어 주세요.',
  'maint.readHead': '멈추기 전, 모두의 글',
  'maint.readNote': '읽기만 할 수 있어요. 여기서는 답글도, 반응도 할 수 없어요.',
  'maint.cw': '보고 싶을 때만 열기',
  'maint.about': '이 서버에 대하여'
};

export const enMaintenance: Record<keyof typeof jaMaintenance, string> = {
  'maint.title': 'Under maintenance',
  'maint.lead': 'We’re looking after the server right now. Posting and replying are paused until we’re done.',
  'maint.kept': 'Everything you’ve shared with us is being kept safe.',
  'maint.why.update': 'We’re moving to a newer version.',
  'maint.why.backup': 'We’re making a backup.',
  'maint.why.migration': 'We’re moving the data to a new home.',
  'maint.why.repair': 'We’re fixing something that broke.',
  'maint.eta': 'We expect to be back in {when}, though it may take longer.',
  'maint.etaLong': 'This one may take a while.',
  'maint.etaUnknown': 'We don’t know yet when we’ll be back.',
  'maint.back': 'When it’s over, just open this page again.',
  'maint.readHead': 'Posts from just before we paused',
  'maint.readNote': 'Reading only: you can’t reply or favourite from here.',
  'maint.cw': 'Open if you’d like to read it',
  'maint.about': 'About this server'
};
