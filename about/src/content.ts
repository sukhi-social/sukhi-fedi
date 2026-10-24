// SPDX-License-Identifier: AGPL-3.0-or-later
//
// このページの言葉は、ここにまとめてある。ja を正本に、ko は同じ形で。
// 文体は web/ の locales に合わせて、やさしく(ja)・해요체(ko)。

// ログインのリンク先。sukhi.social で sukhi-fedi を動かすようになったら、
// ここだけを本当の場所に差し替える(いまは仮)。
export const LOGIN_URL = 'https://sukhi.social/login';

export const ORG_URL = 'https://github.com/sukhi-social';
export const FEDI_REPO_URL = 'https://github.com/sukhi-social/sukhi-fedi';
export const ATFEDI_URL = 'https://atfedi.de';

export type Locale = 'ja' | 'ko';
export type PageKey = 'gate' | 'projects' | 'atfedi';

interface Project {
  name: string;
  href: string;
  text: string;
}

interface Door {
  key: Exclude<PageKey, 'gate'>;
  title: string;
  text: string;
}

interface Copy {
  lang: string;
  siteName: string;
  slogan: string;
  login: string;
  loginNote: string;
  langSwitch: string;
  navLabel: string;
  nav: Record<PageKey, string>;
  footer: string;
  notFound: { title: string; text: string; back: string };
  gate: { title: string; description: string; lead: string; doorsHeading: string; doors: Door[] };
  projects: {
    title: string;
    description: string;
    heading: string;
    lead: string;
    itemsHeading: string;
    items: Project[];
    more: string;
  };
  atfedi: {
    title: string;
    description: string;
    heading: string;
    what: string[];
    facts: string[];
    relHeading: string;
    rel: string[];
    open: string;
  };
}

export const copy: Record<Locale, Copy> = {
  ja: {
    lang: '日本語',
    siteName: 'sukhi',
    slogan: 'あたたかいみんなといっしょに',
    login: 'ログイン',
    loginNote: 'すでにアカウントがあるかたは、こちらから。',
    langSwitch: '한국어',
    navLabel: 'ページ',
    nav: { gate: '玄関', projects: 'sukhi-social のこと', atfedi: 'atfedi.de とのこと' },
    footer: 'sukhi は、sukhi-social がつくっています。',
    notFound: {
      title: 'あれれ、ここには何もないみたいです',
      text: '道をまちがえても大丈夫。玄関までいっしょに戻りましょう。',
      back: '玄関にもどる'
    },
    gate: {
      title: 'sukhi — あたたかいみんなといっしょに',
      description: 'sukhi は、人があつまれて、ふらっと立ち寄れる、あたたかい場所をつくっています。',
      lead: 'sukhi-social は、人があつまれて、さらっと立ち寄れる場所をつくろうとしています。ずっといても、ちょっと顔を出すだけでも、大丈夫。いそがず、ゆっくり見ていってください。',
      doorsHeading: 'どこから見ましょうか',
      doors: [
        { key: 'projects', title: 'sukhi-social のこと', text: 'どんな場所をつくろうとしているのか、なにをつくっているのかを書きました。' },
        { key: 'atfedi', title: 'atfedi.de とのこと', text: 'フェディバースのカタログ atfedi.de と、sukhi のかんけいを書きました。' }
      ]
    },
    projects: {
      title: 'sukhi-social のこと — sukhi',
      description: 'sukhi-social がつくろうとしている場所と、いまつくっているものの紹介です。',
      heading: 'sukhi-social のこと',
      lead: 'sukhi-social は、人があつまれて、さらっと訪ねられる空間をつくろうとしている、GitHub の組織です。ここは、その入口です。つくっているものは、ぜんぶ公開していて、だれでも読めます。',
      itemsHeading: 'いま、つくっているもの',
      items: [
        { name: 'sukhi-fedi', href: FEDI_REPO_URL, text: 'この場所の土台にするソフトウェア。Mastodon / Misskey の API と互換性のある、フェディバースの SNS サーバー。' },
        { name: 'atfedi.de', href: ATFEDI_URL, text: 'フェディバースのツールを集めたカタログ。くわしくは「atfedi.de とのこと」で。' },
        { name: 'mazemaze-api', href: 'https://github.com/sukhi-social/mazemaze-api', text: 'Misskey / Mastodon / Bluesky などの API クライアントを、ひとつの生成器から作る試み。' },
        { name: 'ojak-ex', href: 'https://github.com/sukhi-social/ojak-ex', text: 'Elixir 向けの、署名と JSON-LD のライブラリ。' }
      ],
      more: 'GitHub で ぜんぶ見る'
    },
    atfedi: {
      title: 'atfedi.de とのこと — sukhi',
      description: 'フェディバースのツールのカタログ atfedi.de と、sukhi のかんけいについて。',
      heading: 'atfedi.de とのこと',
      what: [
        'atfedi.de は、フェディバースのツールを集めた、開かれたカタログです。はじめてフェディバースに来た人に向けて、やさしく案内しています。',
        'まよっても、まだよく知らなくても大丈夫。ここには、いそいでいる人はいません。そんな気持ちで、つくっています。'
      ],
      facts: [
        '「使う」と「つくる」の 2 つの入り口があります。',
        '日本語・英語・韓国語で読めます。',
        'ページの内容は CC0 で、自由に写して、直して、わけあえます。',
        '姉妹サイトは joinfediverse.kr(サーバー選びのお手伝い)です。'
      ],
      relHeading: 'sukhi とのかんけい',
      rel: [
        'sukhi-social がつくろうとしているのは、人があつまって「過ごす」場所です。atfedi.de は、フェディバースで使えるものを「さがす」ための地図です。',
        'atfedi.de は、sukhi-social のサブプロジェクトです。ソースコードも、sukhi-social の GitHub にあります。',
        'どちらも、「あたたかく、いそがずに」という気持ちを分けあっています。'
      ],
      open: 'atfedi.de をひらく'
    }
  },
  ko: {
    lang: '한국어',
    siteName: 'sukhi',
    slogan: '따뜻한 사람들과 함께',
    login: '로그인',
    loginNote: '이미 계정이 있다면 여기로 오세요.',
    langSwitch: '日本語',
    navLabel: '페이지',
    nav: { gate: '현관', projects: 'sukhi-social 이야기', atfedi: 'atfedi.de 이야기' },
    footer: 'sukhi는 sukhi-social이 만들고 있어요.',
    notFound: {
      title: '어라, 여기엔 아무것도 없는 것 같아요',
      text: '길을 잘못 들어도 괜찮아요. 현관까지 같이 돌아가요.',
      back: '현관으로 돌아가기'
    },
    gate: {
      title: 'sukhi — 따뜻한 사람들과 함께',
      description: 'sukhi는 사람들이 모이고, 가볍게 들를 수 있는 따뜻한 공간을 만들고 있어요.',
      lead: 'sukhi-social은 사람들이 모일 수 있고, 가볍게 들를 수도 있는 공간을 만들려고 해요. 오래 머물러도, 잠깐 얼굴만 비춰도 괜찮아요. 서두르지 말고 천천히 둘러보세요.',
      doorsHeading: '어디부터 볼까요',
      doors: [
        { key: 'projects', title: 'sukhi-social 이야기', text: '어떤 공간을 만들려는지, 무엇을 만들고 있는지 적었어요.' },
        { key: 'atfedi', title: 'atfedi.de 이야기', text: '페디버스 카탈로그 atfedi.de와 sukhi의 관계를 적었어요.' }
      ]
    },
    projects: {
      title: 'sukhi-social 이야기 — sukhi',
      description: 'sukhi-social이 만들려는 공간과 지금 만들고 있는 것을 소개해요.',
      heading: 'sukhi-social 이야기',
      lead: 'sukhi-social은 사람들이 모이고 가볍게 들를 수 있는 공간을 만들려는 GitHub 조직이에요. 여기는 그 입구예요. 만들고 있는 것은 모두 공개되어 있어서 누구나 읽을 수 있어요.',
      itemsHeading: '지금 만들고 있는 것',
      items: [
        { name: 'sukhi-fedi', href: FEDI_REPO_URL, text: '이 공간의 토대로 쓸 소프트웨어예요. Mastodon / Misskey API와 호환되는 페디버스 SNS 서버예요.' },
        { name: 'atfedi.de', href: ATFEDI_URL, text: '페디버스 도구를 모아 둔 카탈로그예요. 자세한 이야기는 ‘atfedi.de 이야기’에서 해요.' },
        { name: 'mazemaze-api', href: 'https://github.com/sukhi-social/mazemaze-api', text: 'Misskey / Mastodon / Bluesky 등의 API 클라이언트를 하나의 생성기에서 만드는 시도예요.' },
        { name: 'ojak-ex', href: 'https://github.com/sukhi-social/ojak-ex', text: 'Elixir용 서명 및 JSON-LD 라이브러리예요.' }
      ],
      more: 'GitHub에서 모두 보기'
    },
    atfedi: {
      title: 'atfedi.de 이야기 — sukhi',
      description: '페디버스 도구 카탈로그 atfedi.de와 sukhi의 관계에 대해서.',
      heading: 'atfedi.de 이야기',
      what: [
        'atfedi.de는 페디버스 도구를 모아 둔 열린 카탈로그예요. 페디버스에 처음 온 분들을 위해 부드럽게 안내해요.',
        '헤매도, 아직 잘 몰라도 괜찮아요. 여기에는 서두르는 사람이 없어요. 그런 마음으로 만들고 있어요.'
      ],
      facts: [
        '‘사용하기’와 ‘만들기’ 두 개의 입구가 있어요.',
        '일본어·영어·한국어로 읽을 수 있어요.',
        '페이지 내용은 CC0라서 자유롭게 복사하고 고치고 나눌 수 있어요.',
        '자매 사이트는 joinfediverse.kr(서버 고르기를 도와줘요)이에요.'
      ],
      relHeading: 'sukhi와의 관계',
      rel: [
        'sukhi-social이 만들려는 것은 사람들이 모여 ‘지내는’ 공간이에요. atfedi.de는 페디버스에서 쓸 수 있는 것을 ‘찾는’ 지도예요.',
        'atfedi.de는 sukhi-social의 서브 프로젝트예요. 소스 코드도 sukhi-social의 GitHub에 있어요.',
        '둘 다 ‘따뜻하게, 서두르지 않고’라는 마음을 나누고 있어요.'
      ],
      open: 'atfedi.de 열기'
    }
  }
};
