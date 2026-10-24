// SPDX-License-Identifier: AGPL-3.0-or-later
// Messages that the types in the documents must reject. Each line below the
// comment `// @ts-expect-error` must fail to compile; if it compiles, the
// checker reports it.

/** @type {QuoteNote} a quote with the quoteUrl form only */
// @ts-expect-error
const q1 = { type: 'Note', quoteUrl: 'https://remote.example/notes/1' };

/** @type {NoteText} _misskey_content without source */
// @ts-expect-error
const n1 = { _misskey_content: '**x**' };

/** @type {NoteText} source with another media type */
// @ts-expect-error
const n2 = { _misskey_content: 'x', source: { content: 'x', mediaType: 'text/markdown' } };

/** @type {PollVote} a vote that carries content */
const v1 = {
  type: 'Create',
  actor: 'https://sukhi.social/users/hina',
  object: {
    type: 'Note',
    attributedTo: 'https://sukhi.social/users/hina',
    name: 'x',
    inReplyTo: 'https://remote.example/notes/9',
    // @ts-expect-error
    content: 'hi',
  },
};

/** @type {WebFingerAnswer} first link is not self */
const w1 = {
  subject: 'acct:hina@sukhi.social',
  // @ts-expect-error
  links: [{ rel: 'http://webfinger.net/rel/profile-page', href: 'https://sukhi.social/@hina' }],
};

/** @type {EmojiTag} a shortcode without colons */
const e1 = {
  type: 'Emoji',
  // @ts-expect-error
  name: 'blobcat',
  icon: { type: 'Image', url: 'https://x.example/a.png' },
};
