// SPDX-License-Identifier: AGPL-3.0-or-later
// A page of the timeline: the loose time words, the reordering within a
// moment, and the HTML of every card.

import { bench, describe } from 'vitest';
import { spreadWithinMoments } from '../server/shuffle.ts';
import { timeWords } from '../server/time.ts';
import { statusCard } from '../server/views/status.ts';
import { makeCtx, ME, NOW, TIMELINE } from './fixtures.ts';

const ctx = makeCtx('ja');

describe('time', () => {
  bench('timeWords: 40 statuses', () => {
    for (const s of TIMELINE) timeWords(s.created_at, 'ja', NOW, 'Asia/Tokyo');
  });
});

describe('shuffle', () => {
  bench('spreadWithinMoments: 40 statuses', () => {
    spreadWithinMoments(TIMELINE, 'ja', 'seed', NOW, 'Asia/Tokyo');
  });
});

describe('status card', () => {
  bench('statusCard: one status, signed in', () => {
    String(statusCard(ctx, TIMELINE[0], { me: ME }));
  });

  bench('statusCard: 40 statuses, signed out', () => {
    for (const s of TIMELINE) String(statusCard(ctx, s, { me: null }));
  });
});
