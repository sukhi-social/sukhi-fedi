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

interface Project {
  name: string;
  href: string;
  text: string;
}

interface Copy {
  lang: string;
  title: string;
  description: string;
  slogan: string;
  lead: string;
  login: string;
  loginNote: string;
  langSwitch: string;
  orgHeading: string;
  orgText: string;
  orgLink: string;
  projects: Project[];
  atfediHeading: string;
  atfediText: string[];
  atfediFacts: string[];
  atfediLink: string;
  footer: string;
}

export const copy: Record<Locale, Copy> = {
  ja: {
    lang: '日本語',
    title: 'sukhi — あたたかいみんなといっしょに',
    description: 'sukhi は、あたたかいみんなといっしょに、フェディバースで暮らすための小さな場所です。',
    slogan: 'あたたかいみんなといっしょに',
    lead: 'sukhi は、フェディバースにある、ちいさな SNS とその仲間たちです。いそがなくて大丈夫。ゆっくり、見てまわってください。',
    login: 'ログイン',
    loginNote: 'すでにアカウントがあるかたは、こちらから。',
    langSwitch: '한국어',
    orgHeading: 'sukhi-social について',
    orgText:
      'sukhi-social は、sukhi をつくっている GitHub の組織です。ソースコードはぜんぶ公開していて、だれでも読めます。',
    orgLink: 'GitHub で見る',
    projects: [
      {
        name: 'sukhi-fedi',
        href: FEDI_REPO_URL,
        text: 'sukhi の本体です。Mastodon / Misskey の API と互換性のある、フェディバースの SNS サーバー。'
      },
      {
        name: 'atfedi.de',
        href: ATFEDI_URL,
        text: 'フェディバースのツールを集めたカタログ。くわしくは、このすぐ下で。'
      },
      {
        name: 'mazemaze-api',
        href: 'https://github.com/sukhi-social/mazemaze-api',
        text: 'Misskey / Mastodon / Bluesky などの API クライアントを、ひとつの生成器から作る試み。'
      },
      {
        name: 'ojak-ex',
        href: 'https://github.com/sukhi-social/ojak-ex',
        text: 'Elixir 向けの、署名と JSON-LD のライブラリ。'
      }
    ],
    atfediHeading: 'atfedi.de',
    atfediText: [
      'atfedi.de は、フェディバースのツールを集めた、開かれたカタログです。はじめてフェディバースに来た人に向けて、やさしく案内しています。',
      'まよっても、まだよく知らなくても大丈夫。ここには、いそいでいる人はいません。そんな気持ちで、つくっています。'
    ],
    atfediFacts: [
      '「使う」と「つくる」の 2 つの入り口があります。',
      '日本語・英語・韓国語で読めます。',
      'ページの内容は CC0 で、自由に写して、直して、わけあえます。',
      '姉妹サイトは joinfediverse.kr(サーバー選びのお手伝い)です。'
    ],
    atfediLink: 'atfedi.de をひらく',
    footer: 'sukhi は、sukhi-social がつくっています。'
  },
  ko: {
    lang: '한국어',
    title: 'sukhi — 따뜻한 사람들과 함께',
    description: 'sukhi는 따뜻한 사람들과 함께 연합우주(페디버스)에서 지내는 작은 공간이에요.',
    slogan: '따뜻한 사람들과 함께',
    lead: 'sukhi는 페디버스에 있는 작은 SNS와 그 친구들이에요. 서두르지 않아도 괜찮아요. 천천히 둘러보세요.',
    login: '로그인',
    loginNote: '이미 계정이 있다면 여기로 오세요.',
    langSwitch: '日本語',
    orgHeading: 'sukhi-social 이야기',
    orgText:
      'sukhi-social은 sukhi를 만드는 GitHub 조직이에요. 소스 코드는 모두 공개되어 있어서 누구나 읽을 수 있어요.',
    orgLink: 'GitHub에서 보기',
    projects: [
      {
        name: 'sukhi-fedi',
        href: FEDI_REPO_URL,
        text: 'sukhi의 본체예요. Mastodon / Misskey API와 호환되는 페디버스 SNS 서버예요.'
      },
      {
        name: 'atfedi.de',
        href: ATFEDI_URL,
        text: '페디버스 도구를 모아 둔 카탈로그예요. 자세한 이야기는 바로 아래에서 해요.'
      },
      {
        name: 'mazemaze-api',
        href: 'https://github.com/sukhi-social/mazemaze-api',
        text: 'Misskey / Mastodon / Bluesky 등의 API 클라이언트를 하나의 생성기에서 만드는 시도예요.'
      },
      {
        name: 'ojak-ex',
        href: 'https://github.com/sukhi-social/ojak-ex',
        text: 'Elixir용 서명 및 JSON-LD 라이브러리예요.'
      }
    ],
    atfediHeading: 'atfedi.de',
    atfediText: [
      'atfedi.de는 페디버스 도구를 모아 둔 열린 카탈로그예요. 페디버스에 처음 온 분들을 위해 부드럽게 안내해요.',
      '헤매도, 아직 잘 몰라도 괜찮아요. 여기에는 서두르는 사람이 없어요. 그런 마음으로 만들고 있어요.'
    ],
    atfediFacts: [
      '‘사용하기’와 ‘만들기’ 두 개의 입구가 있어요.',
      '일본어·영어·한국어로 읽을 수 있어요.',
      '페이지 내용은 CC0라서 자유롭게 복사하고 고치고 나눌 수 있어요.',
      '자매 사이트는 joinfediverse.kr(서버 고르기를 도와줘요)이에요.'
    ],
    atfediLink: 'atfedi.de 열기',
    footer: 'sukhi는 sukhi-social이 만들고 있어요.'
  }
};
