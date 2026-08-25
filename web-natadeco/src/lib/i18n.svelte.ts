// 表示言語(日本語/韓国語)。仕組みは theme.ts と同じ ── 選べば
// localStorage に残り、選ばなければ日本語のまま。ここは全ページから
// 読まれるので、$state をモジュールに持たせて共有する(theme.ts は
// コンポーネントごとに読み直す作りだったが、こちらは辞書がページ全体に
// 散らばるので、切り替えた瞬間に画面全体が動いてほしい)。

import { browser } from '$app/environment';

const KEY = 'nd.lang';

export type Lang = 'ja' | 'ko';

export const langNames: Record<Lang, string> = {
  ja: '日本語',
  ko: '한국어'
};

function readStored(): Lang {
  if (!browser) return 'ja';
  return localStorage.getItem(KEY) === 'ko' ? 'ko' : 'ja';
}

let lang = $state<Lang>(readStored());

export function getLang(): Lang {
  return lang;
}

export function setLang(l: Lang): void {
  lang = l;
  if (browser) {
    localStorage.setItem(KEY, l);
    document.documentElement.lang = l;
  }
}

export function toggleLang(): Lang {
  setLang(lang === 'ko' ? 'ja' : 'ko');
  return lang;
}

type TwoPart = { prefix: string; link: string; suffix: string };

type Dict = {
  siteName: string;
  themeToggle: { toLight: string; toDark: string };
  nav: {
    boardList: string;
    home: string;
    profile: string;
    signOut: string;
    signIn: string;
    account: string;
    switchLanguage: (name: string) => string;
  };
  common: { loading: string; toDecoList: string; optional: string };
  home: {
    title: string;
    separator: string;
    subtitle: string;
    loadError: string;
    empty: string;
    postCount: (n: number) => string;
    openForm: string;
    fields: { name: string; slug: string; description: string };
    submit: string;
    cancel: string;
    createError: string;
    needOneLang: string;
  };
  board: {
    notFound: string;
    notFoundFallback: string;
    write: string;
    readOnly: TwoPart;
    empty: string;
    colNum: string;
    colTitle: string;
    colAuthor: string;
    colDate: string;
    untitled: string;
    end: string;
    more: string;
  };
  newPost: {
    notFound: string;
    title: (name: string) => string;
    tip: string;
    tipClose: string;
    fieldTitle: string;
    fieldBody: string;
    bodyPlaceholder: string;
    formatHint: string;
    submit: string;
    submitting: string;
    postedAs: string;
    error: string;
    back: (name: string) => string;
    needOneLang: string;
  };
  postDetail: {
    notFound: string;
    notFoundFallback: string;
    replyPlaceholder: string;
    send: string;
    readOnly: TwoPart;
    error: string;
    edit: string;
    editCancel: string;
    editSave: string;
    editSaving: string;
    editError: string;
    delete: string;
    deleteConfirm: string;
    deleteConfirmYes: string;
    deleteError: string;
  };
  login: {
    title: string;
    tabEmail: string;
    tabPassword: string;
    handle: string;
    password: string;
    submit: string;
    email: string;
    sendCode: string;
    codeSent: (email: string) => string;
    code: string;
    errorGeneric: string;
    errorInvalid: string;
    errorSendFailed: string;
    errorCodeInvalid: string;
    passkey: string;
    passkeyFailed: string;
    signupLink: string;
  };
  signup: {
    title: string;
    welcome: string;
    intro: string;
    readFirst: (link: string) => string;
    agree: (terms: string, privacy: string) => string;
    handle: string;
    email: string;
    emailHint: string;
    password: string;
    sendCode: string;
    codeSent: (email: string) => string;
    code: string;
    create: string;
    warmthTitle: string;
    warmthBody1: string;
    warmthBody2: string;
    warmthQuestion: string;
    warmthField: string;
    warmthPlaceholder: string;
    finish: string;
    finishing: string;
    creating: string;
    errorSendFailed: string;
    errorEmailTaken: string;
    errorCodeInvalid: string;
    errorValidation: string;
    errorGeneric: string;
    loginLink: string;
    backToHello: string;
    passkeyTitle: string;
    passkeyBody1: string;
    passkeyBody2: string;
    passkeyAdd: string;
    passkeyAdding: string;
    passkeySkip: string;
    passkeyFailed: string;
  };
  settings: {
    title: string;
    loadError: TwoPart;
    displayName: string;
    note: string;
    save: string;
    saving: string;
    saved: string;
    error: string;
    notifyLabel: string;
    notifyOn: string;
    notifyOff: string;
    notifyUnsupported: string;
    notifyDenied: string;
    securityLink: string;
  };
  security: {
    title: string;
    intro: string;
    signInAgain: TwoPart;
    none: string;
    unnamed: string;
    added: (date: string) => string;
    lastUsed: (date: string) => string;
    neverUsed: string;
    nickname: string;
    add: string;
    adding: string;
    unsupported: string;
    remove: string;
    removing: string;
    removeIntro: string;
    password: string;
    sendReauth: string;
    reauthSent: string;
    reauthCode: string;
    cancel: string;
    errorDup: string;
    errorReauth: string;
    errorGeneric: string;
    backToSettings: string;
  };
  callback: {
    serverError: (err: string) => string;
    noCode: string;
    failedTitle: string;
    working: string;
  };
  footer: { terms: string; privacy: string };
  visibility: { label: string; public: string; local: string; hint: string; badge: string };
  reactions: { add: string };
  decoReach: {
    legend: string;
    openLabel: string;
    openHint: string;
    insideLabel: string;
    insideHint: string;
  };
  toolbar: { bold: string; italic: string; link: string; list: string; quote: string; heading: string };
  hinata: { reveal: string; hide: string };
  hello: { title: string; greeting: string; aiNotice: string; start: string };
};

const ja: Dict = {
  siteName: 'ナタデコ',
  themeToggle: { toLight: '明るい色にする', toDark: '暗い色にする' },
  nav: {
    boardList: '板の一覧',
    home: 'ホーム',
    profile: 'プロフィール',
    signOut: '出る',
    signIn: '入る',
    account: 'アカウント',
    switchLanguage: (name) => `${name}に切り替え`
  },
  common: { loading: 'よみこみ中', toDecoList: 'デコの一覧へ', optional: 'なくてもいい' },
  home: {
    title: 'デコ',
    separator: ' ',
    subtitle: '板が「デコ」です。好きなところに座ってください。',
    loadError: '板の一覧が読めませんでした',
    empty: 'まだ、どの板もありません。',
    postCount: (n) => `${n} 件`,
    openForm: '板を立てる',
    fields: {
      name: '名前',
      slug: 'URL に出る名前（英小文字・数字・- _）',
      description: 'どんな板か（なくてもいい）'
    },
    submit: '立てる',
    cancel: 'やめる',
    createError: 'その名前では立てられませんでした（すでにある名前か、使えない形かも）',
    needOneLang: 'どちらかの言語で、名前を書いてください。'
  },
  board: {
    notFound: 'この板は見つかりませんでした',
    notFoundFallback: 'この板はありません',
    write: '書く',
    readOnly: { prefix: '読むのは誰でも。書くには、', link: '入って', suffix: 'ください。' },
    empty: 'まだ、なにもありません。最初の一つに、なれます。',
    colNum: '番号',
    colTitle: 'タイトル',
    colAuthor: '作成者',
    colDate: '作成日',
    untitled: '(無題)',
    end: 'ここまでです。',
    more: 'もっと読む'
  },
  newPost: {
    notFound: 'この板は見つかりませんでした',
    title: (name) => `${name} に書く`,
    tip: '書きかけは、自動でここに残ります。あわてなくて大丈夫です。',
    tipClose: 'とじる',
    fieldTitle: '題',
    fieldBody: '本文',
    bodyPlaceholder: 'なにか、どうぞ',
    formatHint: '**太字**・[リンク](url)・#タグ・@名前 が使えます。Cmd/Ctrl + Enter でも送れます。',
    submit: '書く',
    submitting: 'おくっています…',
    postedAs: 'あなたの名前で出ます',
    error: '書けませんでした',
    back: (name) => `${name} にもどる`,
    needOneLang: 'どちらかの言語で、題と本文を両方書いてください。'
  },
  postDetail: {
    notFound: 'この投稿は見つかりませんでした',
    notFoundFallback: 'この投稿はありません',
    replyPlaceholder: 'つづきを、どうぞ',
    send: 'おくる',
    readOnly: { prefix: '読むのは誰でも。書くには、', link: '入って', suffix: 'ください。' },
    error: '書けませんでした',
    edit: '直す',
    editCancel: 'やめる',
    editSave: 'なおす',
    editSaving: 'なおしています…',
    editError: '直せませんでした',
    delete: 'なくす',
    deleteConfirm: '本当に、なくす? もとには戻せません。',
    deleteConfirmYes: 'なくす',
    deleteError: '消せませんでした'
  },
  login: {
    title: '入る',
    tabEmail: 'メールのコード',
    tabPassword: '合言葉',
    handle: '@ハンドル',
    password: '合言葉',
    submit: '入る',
    email: 'メールアドレス',
    sendCode: 'コードを送る',
    codeSent: (email) => `${email} にコードを送りました`,
    code: '6桁のコード',
    errorGeneric: '入れませんでした',
    errorInvalid: '名前か合言葉が違います',
    errorSendFailed: '送れませんでした',
    errorCodeInvalid: 'コードが違うか、古くなっています',
    passkey: 'パスキーで入る',
    passkeyFailed: 'パスキーで入れませんでした',
    signupLink: 'はじめての方はこちら'
  },
  signup: {
    title: 'はじめる',
    welcome: 'ようこそ。ひなたです。',
    intro: 'ここで、あなたのことを少し教えてください。',
    readFirst: (link) => `はじめる前に、大事なことを${link}に書いておきました。ひと目、見ていってください。`,
    agree: (terms, privacy) => `${terms}と${privacy}に同意します`,
    handle: '@ハンドル(英小文字・数字・_、あとから変えられません)',
    email: 'メールアドレス',
    emailHint: 'アカウントをなくしたとき、ここから帰ってこられます。',
    password: '合言葉(なくてもいい ── メールのコードだけで入れます)',
    sendCode: 'コードを送る',
    codeSent: (email) => `${email} にコードを送りました`,
    code: '6桁のコード',
    create: 'つくる',
    warmthTitle: 'さいごに。',
    warmthBody1: 'ひなたは、みんなに「あたたかい」ことを聞いています。',
    warmthBody2: 'あたたかい場所がいいと、信じているから。',
    warmthQuestion: 'あなたにとって、今、あたたかいと感じるものは何ですか?',
    warmthField: 'もしよければ、一言でも、どうぞ。',
    warmthPlaceholder: 'こたえなくても、いいです',
    finish: 'ナタデコへ',
    finishing: 'すすんでいます…',
    creating: 'つくっています…',
    errorSendFailed: 'コードを送れませんでした',
    errorEmailTaken: 'そのメールアドレスは、もう使われています',
    errorCodeInvalid: 'コードが古いか、違っています',
    errorValidation: 'ユーザー名か、コードを見直してください',
    errorGeneric: '作れませんでした',
    loginLink: 'もうアカウントがある方はこちら',
    backToHello: '「はじめる前に」へもどる',
    passkeyTitle: 'この端末を、鍵にできます。',
    passkeyBody1: '次からは、メールのコードを待たずに、指紋や顔だけで入れます。',
    passkeyBody2: 'あとから設定でも足せるので、いまでなくても大丈夫です。',
    passkeyAdd: 'この端末を鍵にする',
    passkeyAdding: '登録しています…',
    passkeySkip: 'あとで',
    passkeyFailed: '登録できませんでした。あとから設定でできます。'
  },
  settings: {
    title: 'プロフィール',
    loadError: { prefix: '読めませんでした。', link: '入りなおして', suffix: 'ください。' },
    displayName: '表示する名前',
    note: '自己紹介(なくてもいい)',
    save: 'ほぞんする',
    saving: 'ほぞんしています…',
    saved: 'ほぞんしました',
    error: '保存できませんでした',
    notifyLabel: '通知',
    notifyOn: '自分の投稿に返信があったら、知らせます',
    notifyOff: '今は、知らせていません',
    notifyUnsupported: 'このブラウザでは、通知を使えません',
    notifyDenied: '通知が、ブロックされています。ブラウザの設定から許可してください。',
    securityLink: 'パスキー(入りかたの設定)'
  },
  security: {
    title: 'パスキー',
    intro:
      '合言葉のかわりに、この端末の指紋や顔で入れる鍵です。ひとつ登録しておくと、次からはメールのコードを待たずに入れます。',
    signInAgain: { prefix: 'ここは、', link: '入りなおして', suffix: 'から触れます。' },
    none: 'まだ、鍵はありません。',
    unnamed: '名前のない鍵',
    added: (date) => `${date} に登録`,
    lastUsed: (date) => `さいごに使ったのは ${date}`,
    neverUsed: 'まだ使っていません',
    nickname: 'この鍵の名前(なくてもいい)',
    add: 'この端末を鍵にする',
    adding: '登録しています…',
    unsupported: 'このブラウザでは、パスキーを使えません。',
    remove: 'はずす',
    removing: 'はずしています…',
    removeIntro: 'はずす前に、本人確認をします。',
    password: '合言葉',
    sendReauth: '確認のコードを送る',
    reauthSent: 'メールにコードを送りました',
    reauthCode: '6桁のコード',
    cancel: 'やめる',
    errorDup: 'この端末は、もう登録されています',
    errorReauth: '確認できませんでした',
    errorGeneric: 'できませんでした',
    backToSettings: 'プロフィールの設定へ'
  },
  callback: {
    serverError: (err) => `サーバから: ${err}`,
    noCode: 'コードが見当たりません',
    failedTitle: '入れませんでした',
    working: '入っています…'
  },
  footer: { terms: '利用規約', privacy: 'プライバシーポリシー' },
  visibility: {
    label: '公開範囲',
    public: '全域',
    local: 'ローカル',
    hint: '全域は連合(他のサーバー)にも届きます。ローカルは natadeco の中だけ。',
    badge: 'ローカル'
  },
  reactions: { add: 'ひとつ、そえる' },
  decoReach: {
    legend: 'この板は',
    openLabel: '外にひらく',
    openHint: '外から見つけてもらえます。書いたものは、そのまま外にも届きます。',
    insideLabel: 'うちの中に',
    insideHint: 'ここに居る人だけの場所です。書いたものも、一件ずつ選べば外に出せます。'
  },
  toolbar: { bold: '太字', italic: '斜体', link: 'リンク', list: 'リスト', quote: '引用', heading: '見出し' },
  hinata: { reveal: 'ひなたを見てみる', hide: 'ひなたを隠す' },
  hello: {
    title: 'はじめる前に',
    greeting: 'ようこそ。ひなたです。',
    aiNotice: 'ひなたの絵は、AIで描かれたものです。見せてもいいですか?下のスイッチで、いつでも切り替えられます。',
    start: 'はじめる'
  }
};

const ko: Dict = {
  siteName: '나타데코',
  themeToggle: { toLight: '밝게 하기', toDark: '어둡게 하기' },
  nav: {
    boardList: '데코 목록',
    home: '홈',
    profile: '프로필',
    signOut: '나가기',
    signIn: '들어가기',
    account: '계정',
    switchLanguage: (name) => `${name}(으)로 전환`
  },
  common: { loading: '불러오는 중', toDecoList: '데코 목록으로', optional: '안 적어도 돼요' },
  home: {
    title: '데코',
    separator: ' ',
    subtitle: "게시판을 '데코'라고 불러요. 마음에 드는 곳에 앉아 보세요.",
    loadError: '데코 목록을 불러오지 못했어요',
    empty: '아직 만들어진 데코가 없어요.',
    postCount: (n) => `${n}개`,
    openForm: '데코 만들기',
    fields: {
      name: '이름',
      slug: '주소에 쓸 이름 (영문 소문자·숫자·- _)',
      description: '어떤 데코인지 (안 적어도 돼요)'
    },
    submit: '만들기',
    cancel: '취소',
    createError: '그 이름으로는 만들 수 없었어요 (이미 있는 이름이거나, 쓸 수 없는 형식일 수도 있어요)',
    needOneLang: '한쪽 언어로, 이름을 적어주세요.'
  },
  board: {
    notFound: '이 데코를 찾을 수 없었어요',
    notFoundFallback: '이런 데코는 없어요',
    write: '글쓰기',
    readOnly: { prefix: '누구나 읽을 수 있어요. 글을 쓰려면 ', link: '들어가', suffix: ' 주세요.' },
    empty: '아직 아무 글도 없어요. 첫 글의 주인공이 되어 보세요.',
    colNum: '번호',
    colTitle: '제목',
    colAuthor: '글쓴이',
    colDate: '작성일',
    untitled: '(제목 없음)',
    end: '여기까지예요.',
    more: '더 보기'
  },
  newPost: {
    notFound: '이 데코를 찾을 수 없었어요',
    title: (name) => `${name}에 글쓰기`,
    tip: '쓰다 만 글은 자동으로 저장돼요. 서두르지 않아도 괜찮아요.',
    tipClose: '닫기',
    fieldTitle: '제목',
    fieldBody: '내용',
    bodyPlaceholder: '편하게, 무엇이든 적어보세요',
    formatHint: '**굵게**・[링크](url)・#태그・@이름을 쓸 수 있어요. Cmd/Ctrl + Enter로도 보낼 수 있어요.',
    submit: '글쓰기',
    submitting: '보내는 중…',
    postedAs: '당신의 이름으로 올라가요',
    error: '쓸 수 없었어요',
    back: (name) => `${name}(으)로 돌아가기`,
    needOneLang: '한쪽 언어로, 제목과 내용을 모두 적어주세요.'
  },
  postDetail: {
    notFound: '이 글을 찾을 수 없었어요',
    notFoundFallback: '이런 글은 없어요',
    replyPlaceholder: '이어서, 편하게 적어보세요',
    send: '보내기',
    readOnly: { prefix: '누구나 읽을 수 있어요. 답글을 쓰려면 ', link: '들어가', suffix: ' 주세요.' },
    error: '쓸 수 없었어요',
    edit: '수정하기',
    editCancel: '그만두기',
    editSave: '고치기',
    editSaving: '고치는 중…',
    editError: '수정할 수 없었어요',
    delete: '지우기',
    deleteConfirm: '정말 지울까요? 되돌릴 수 없어요.',
    deleteConfirmYes: '지우기',
    deleteError: '지울 수 없었어요'
  },
  login: {
    title: '들어가기',
    tabEmail: '메일 인증코드',
    tabPassword: '비밀번호',
    handle: '@아이디',
    password: '비밀번호',
    submit: '들어가기',
    email: '이메일 주소',
    sendCode: '코드 보내기',
    codeSent: (email) => `${email}(으)로 코드를 보냈어요`,
    code: '6자리 코드',
    errorGeneric: '들어갈 수 없었어요',
    errorInvalid: '아이디나 비밀번호가 맞지 않아요',
    errorSendFailed: '보낼 수 없었어요',
    errorCodeInvalid: '코드가 틀렸거나, 오래됐어요',
    passkey: '패스키로 들어가기',
    passkeyFailed: '패스키로 들어갈 수 없었어요',
    signupLink: '처음이신가요? 이쪽으로'
  },
  signup: {
    title: '시작하기',
    welcome: '어서 오세요. 히나타예요.',
    intro: '여기서, 당신에 대해 조금 알려주세요.',
    readFirst: (link) => `시작하기 전에, 중요한 이야기를 ${link}에 적어 두었어요. 한번 봐 주세요.`,
    agree: (terms, privacy) => `${terms}과 ${privacy}에 동의해요`,
    handle: '@아이디 (영문 소문자·숫자·_, 나중에 바꿀 수 없어요)',
    email: '이메일 주소',
    emailHint: '계정을 잃어버렸을 때, 여기로 돌아올 수 있어요.',
    password: '비밀번호 (안 만들어도 돼요 ── 메일 코드만으로도 들어올 수 있어요)',
    sendCode: '코드 보내기',
    codeSent: (email) => `${email}(으)로 코드를 보냈어요`,
    code: '6자리 코드',
    create: '만들기',
    warmthTitle: '마지막으로.',
    warmthBody1: '히나타는 모두에게 "따뜻한 것"을 물어보고 있어요.',
    warmthBody2: '따뜻한 곳이 좋다고, 믿고 있으니까요.',
    warmthQuestion: '당신에게 지금, 따뜻하게 느껴지는 건 뭔가요?',
    warmthField: '괜찮다면, 한마디라도 들려주세요.',
    warmthPlaceholder: '대답하지 않아도 괜찮아요',
    finish: '나타데코로',
    finishing: '진행하는 중…',
    creating: '만드는 중…',
    errorSendFailed: '코드를 보낼 수 없었어요',
    errorEmailTaken: '그 이메일 주소는 이미 쓰이고 있어요',
    errorCodeInvalid: '코드가 오래됐거나, 틀렸어요',
    errorValidation: '아이디나 코드를 다시 확인해 주세요',
    errorGeneric: '만들 수 없었어요',
    loginLink: '이미 계정이 있으신가요? 이쪽으로',
    backToHello: "'시작하기 전에'로 돌아가기",
    passkeyTitle: '이 기기를 열쇠로 만들 수 있어요.',
    passkeyBody1: '다음부터는 메일 코드를 기다리지 않고, 지문이나 얼굴만으로 들어올 수 있어요.',
    passkeyBody2: '나중에 설정에서도 추가할 수 있으니, 지금이 아니어도 괜찮아요.',
    passkeyAdd: '이 기기를 열쇠로 만들기',
    passkeyAdding: '등록하는 중…',
    passkeySkip: '나중에',
    passkeyFailed: '등록할 수 없었어요. 나중에 설정에서 할 수 있어요.'
  },
  settings: {
    title: '프로필',
    loadError: { prefix: '불러올 수 없었어요. ', link: '다시 들어가', suffix: ' 주세요.' },
    displayName: '표시할 이름',
    note: '자기소개 (안 적어도 돼요)',
    save: '저장하기',
    saving: '저장하는 중…',
    saved: '저장했어요',
    error: '저장할 수 없었어요',
    notifyLabel: '알림',
    notifyOn: '내 글에 답글이 달리면 알려드려요',
    notifyOff: '지금은 알려드리지 않아요',
    notifyUnsupported: '이 브라우저에서는 알림을 쓸 수 없어요',
    notifyDenied: '알림이 차단되어 있어요. 브라우저 설정에서 허용해 주세요.',
    securityLink: '패스키 (들어오는 방법)'
  },
  security: {
    title: '패스키',
    intro:
      '비밀번호 대신, 이 기기의 지문이나 얼굴로 들어오는 열쇠예요. 하나 등록해 두면 다음부터는 메일 코드를 기다리지 않아도 돼요.',
    signInAgain: { prefix: '여기는 ', link: '다시 들어가', suffix: '신 뒤에 만질 수 있어요.' },
    none: '아직 열쇠가 없어요.',
    unnamed: '이름 없는 열쇠',
    added: (date) => `${date}에 등록`,
    lastUsed: (date) => `마지막으로 쓴 건 ${date}`,
    neverUsed: '아직 쓰지 않았어요',
    nickname: '이 열쇠의 이름 (안 적어도 돼요)',
    add: '이 기기를 열쇠로 만들기',
    adding: '등록하는 중…',
    unsupported: '이 브라우저에서는 패스키를 쓸 수 없어요.',
    remove: '빼기',
    removing: '빼는 중…',
    removeIntro: '빼기 전에, 본인 확인을 할게요.',
    password: '비밀번호',
    sendReauth: '확인 코드 보내기',
    reauthSent: '메일로 코드를 보냈어요',
    reauthCode: '6자리 코드',
    cancel: '그만두기',
    errorDup: '이 기기는 이미 등록되어 있어요',
    errorReauth: '확인하지 못했어요',
    errorGeneric: '할 수 없었어요',
    backToSettings: '프로필 설정으로'
  },
  callback: {
    serverError: (err) => `서버에서: ${err}`,
    noCode: '코드를 찾을 수 없어요',
    failedTitle: '들어갈 수 없었어요',
    working: '들어가는 중…'
  },
  footer: { terms: '이용약관', privacy: '개인정보 처리방침' },
  visibility: {
    label: '공개 범위',
    public: '전역',
    local: '로컬',
    hint: '전역은 연합(다른 서버)에도 전달돼요. 로컬은 natadeco 안에서만 보여요.',
    badge: '로컬'
  },
  reactions: { add: '가볍게 남기기' },
  decoReach: {
    legend: '이 데코는',
    openLabel: '밖으로 열기',
    openHint: '밖에서도 찾을 수 있어요. 쓴 글도 그대로 밖에 닿아요.',
    insideLabel: '안쪽에 두기',
    insideHint: '여기 있는 사람들만의 자리예요. 쓴 글은 하나씩 골라서 밖에 낼 수 있어요.'
  },
  toolbar: { bold: '굵게', italic: '기울임', link: '링크', list: '목록', quote: '인용', heading: '제목' },
  hinata: { reveal: '히나타를 보기', hide: '히나타를 숨기기' },
  hello: {
    title: '시작하기 전에',
    greeting: '어서 오세요. 히나타예요.',
    aiNotice: '히나타의 그림은, AI가 그린 거예요. 보여드려도 될까요? 아래 스위치로, 언제든 바꿀 수 있어요.',
    start: '시작하기'
  }
};

const dicts: Record<Lang, Dict> = { ja, ko };

export function t(): Dict {
  return dicts[lang];
}
