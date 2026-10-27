import assert from 'node:assert';
import { describe, it } from 'vitest';
import type { CardRow } from '../types';
import type { ParsedListEntry } from './parseList';
import { validateDeck } from './deckValidation';

let counter = 0;
function makeCard(overrides: Partial<CardRow> = {}): CardRow {
  const name = overrides.name ?? `Test Card ${counter++}`;
  return {
    oracle_id: overrides.oracle_id ?? name,
    name,
    name_lower: name.toLowerCase(),
    mana_cost: null,
    cmc: 0,
    type_line: 'Creature — Human',
    oracle_text: null,
    colors: '[]',
    color_identity: '[]',
    keywords: '[]',
    creature_types: '[]',
    power: '1',
    toughness: '1',
    scryfall_uri: null,
    partner_ability: null,
    partner_target: null,
    is_background: 0,
    legality_commander: 'legal',
    game_changer: 0,
    is_legendary: 0,
    is_commander_eligible: 0,
    is_changeling: 0,
    image_uri: null,
    back_image_uri: null,
    back_name: null,
    ...overrides,
  };
}

function entry(name: string, quantity = 1): ParsedListEntry {
  return { name, quantity, raw: name };
}

function nameMapOf(cards: CardRow[]): Map<string, CardRow> {
  return new Map(cards.map((c) => [c.name_lower, c]));
}

function eligibleCommander(overrides: Partial<CardRow> = {}): CardRow {
  return makeCard({ is_legendary: 1, is_commander_eligible: 1, ...overrides });
}

describe('validateDeck — deck size (903.5a)', () => {
  it('exactly 100 cards with a legal commander is valid', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });

    const result = validateDeck(
      [entry('Test Commander'), entry('Plains', 99)],
      nameMapOf([commander, makeCard({ name: 'Plains', color_identity: '["W"]' })]),
      [commander],
      [],
    );

    assert.strictEqual(result.isValid, true);
    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.deckSize.isValid, true);
  });

  it('99 cards is invalid — CR 903.5a sets both the minimum and the maximum at 100', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });

    const result = validateDeck(
      [entry('Test Commander'), entry('Plains', 97)],
      nameMapOf([commander, makeCard({ name: 'Plains', color_identity: '["W"]' })]),
      [commander],
      [],
    );

    assert.strictEqual(result.isValid, false);
    assert.strictEqual(result.deckSize.total, 98);
    assert.strictEqual(result.deckSize.isValid, false);
  });

  it('a banned card still occupies a deck slot in the count', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });
    const banned = makeCard({ name: 'Banned Card', legality_commander: 'banned' });

    // 99 legal + 1 banned pasted = a 100-card deck. The count must read 100 —
    // the fix here is "swap the banned card", and a count of 99 would tell the
    // player to add one instead. Regression for the auditor's plan, which only
    // summed `submitted`.
    const result = validateDeck(
      [entry('Test Commander'), entry('Plains', 98), entry('Banned Card')],
      nameMapOf([
        commander,
        makeCard({ name: 'Plains', color_identity: '["W"]' }),
        banned,
      ]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.deckSize.isValid, true);
    assert.deepStrictEqual(result.legality.banned, ['Banned Card']);
    assert.strictEqual(result.isValid, false);
  });

  it('an unparseable card still occupies a deck slot in the count', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });

    const result = validateDeck(
      [entry('Test Commander'), entry('Plains', 97), entry('Not A Real Card', 2)],
      nameMapOf([commander, makeCard({ name: 'Plains', color_identity: '["W"]' })]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.deepStrictEqual(result.legality.notFound, ['Not A Real Card']);
    assert.strictEqual(result.isValid, false);
  });
});

describe('validateDeck — color identity (903.4)', () => {
  it('decodes the JSON-string color_identity column before checking (parseJsonArray)', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["U"]' });
    // The stored column is a JSON string, not an array. Passing it straight to
    // @mtg/rules would iterate its characters instead of its colors.
    const offIdentity = makeCard({ name: 'Illegal Card', color_identity: '["U","W"]' });
    const plainsCount = 97;

    const result = validateDeck(
      [entry('Test Commander'), entry('Illegal Card'), entry('Island', plainsCount)],
      nameMapOf([
        commander,
        offIdentity,
        makeCard({ name: 'Island', color_identity: '["U"]' }),
      ]),
      [commander],
      [],
    );

    assert.strictEqual(result.isValid, false);
    assert.deepStrictEqual(result.colorIdentity.violations, [
      { name: 'Illegal Card', color_identity: ['U', 'W'], quantity: 1 },
    ]);
  });

  it('a colorless deck is vacuously within any identity', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });

    const result = validateDeck(
      [entry('Test Commander'), entry('Artifact Land', 99)],
      nameMapOf([commander, makeCard({ name: 'Artifact Land', color_identity: '[]' })]),
      [commander],
      [],
    );

    assert.strictEqual(result.colorIdentity.violations.length, 0);
    assert.strictEqual(result.isValid, true);
  });
});

describe('validateDeck — commander unit legality (903.3 / 702.124)', () => {
  it('a card that is not commander-eligible cannot be named commander', () => {
    const notEligible = makeCard({ name: 'Sol Ring', color_identity: '[]' });

    const result = validateDeck(
      [entry('Plains', 99)],
      nameMapOf([notEligible, makeCard({ name: 'Plains', color_identity: '["U"]' })]),
      [notEligible],
      [],
    );

    assert.strictEqual(result.commander.eligible, false);
    assert.strictEqual(result.commander.pairingLegal, false);
    assert.strictEqual(result.isValid, false);
  });

  it('a legal Partner pair is one commander unit with the union identity (702.124e)', () => {
    const a = eligibleCommander({
      name: 'Partner A',
      color_identity: '["W"]',
      partner_ability: 'partner',
      creature_types: '["Creature"]',
    });
    const b = eligibleCommander({
      name: 'Partner B',
      color_identity: '["U"]',
      partner_ability: 'partner',
      creature_types: '["Creature"]',
    });

    const result = validateDeck(
      [entry('Partner A'), entry('Partner B'), entry('Plains', 98)],
      nameMapOf([
        a,
        b,
        makeCard({ name: 'Plains', color_identity: '["U"]' }),
      ]),
      [a, b],
      [],
    );

    assert.strictEqual(result.commander.eligible, true);
    assert.strictEqual(result.commander.pairingLegal, true);
    assert.deepStrictEqual(new Set(result.commander.colorIdentity), new Set(['W', 'U']));
    assert.strictEqual(result.isValid, true);
  });

  it('two legendary cards without a pairing ability are not a legal unit', () => {
    const a = eligibleCommander({ name: 'Legend A', color_identity: '["W"]' });
    const b = eligibleCommander({ name: 'Legend B', color_identity: '["U"]' });

    const result = validateDeck(
      [entry('Legend A'), entry('Legend B'), entry('Plains', 98)],
      nameMapOf([a, b, makeCard({ name: 'Plains', color_identity: '["U"]' })]),
      [a, b],
      [],
    );

    assert.strictEqual(result.commander.pairingLegal, false);
    assert.strictEqual(result.isValid, false);
  });

  it('a Background companion needs the legal Background to pair', () => {
    const chooser = eligibleCommander({
      name: 'Commander with Background',
      color_identity: '["W"]',
      partner_ability: 'choose_background',
      creature_types: '["Creature"]',
    });
    const background = makeCard({
      name: 'A Legal Background',
      color_identity: '["W"]',
      partner_ability: null,
      is_background: 1,
    });

    const result = validateDeck(
      [entry('Commander with Background'), entry('Plains', 99)],
      nameMapOf([chooser, makeCard({ name: 'Plains', color_identity: '["W"]' })]),
      [chooser],
      [background],
    );

    assert.strictEqual(result.commander.pairingLegal, true);
    assert.strictEqual(result.isValid, true);
  });
});
describe('validateDeck — named-commander legality and report hygiene', () => {
  const plains = () =>
    makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' });

  it('a banned commander missing from the pasted list is still reported as banned', () => {
    const commander = eligibleCommander({
      name: 'Banned Commander',
      color_identity: '["W"]',
      legality_commander: 'banned',
    });

    // The 100 pasted cards are all Plains: the commander was named separately and is
    // not on the list, so nothing on the list can carry the ban to the verdict.
    const result = validateDeck(
      [entry('Plains', 100)],
      nameMapOf([commander, plains()]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.deckSize.isValid, true);
    assert.strictEqual(result.isValid, false);
    assert.deepStrictEqual(result.legality.banned, ['Banned Commander']);
  });

  it('a commander that is not_legal or restricted is treated the same way', () => {
    for (const status of ['not_legal', 'restricted']) {
      const commander = eligibleCommander({
        name: `Status ${status} Commander`,
        color_identity: '["W"]',
        legality_commander: status,
      });
      const result = validateDeck(
        [entry('Plains', 100)],
        nameMapOf([commander, plains()]),
        [commander],
        [],
      );
      assert.strictEqual(result.isValid, false, status);
      assert.deepStrictEqual(result.legality.banned, [commander.name], status);
    }
  });

  it('a banned commander that is also on the list is reported once and fills one slot', () => {
    const commander = eligibleCommander({
      name: 'Banned Commander',
      color_identity: '["W"]',
      legality_commander: 'banned',
    });

    const result = validateDeck(
      [entry('Banned Commander'), entry('Plains', 99)],
      nameMapOf([commander, plains()]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.deepStrictEqual(result.legality.banned, ['Banned Commander']);
    assert.strictEqual(result.isValid, false);
  });

  it('the same commander written in another case on the list is still reported once', () => {
    const commander = eligibleCommander({
      name: 'Banned Commander',
      color_identity: '["W"]',
      legality_commander: 'banned',
    });

    const result = validateDeck(
      [entry('banned commander'), entry('Plains', 99)],
      nameMapOf([commander, plains()]),
      [commander],
      [],
    );

    assert.strictEqual(result.legality.banned.length, 1);
    assert.strictEqual(result.legality.banned[0]!.toLowerCase(), 'banned commander');
  });

  it('a legal commander that is not on the list adds nothing to banned', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });

    const result = validateDeck(
      [entry('Plains', 100)],
      nameMapOf([commander, plains()]),
      [commander],
      [],
    );

    assert.deepStrictEqual(result.legality.banned, []);
    assert.strictEqual(result.isValid, true);
  });

  it('a banned card on two lines is reported once, and both copies still fill slots', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });
    const banned = makeCard({ name: 'Banned Card', legality_commander: 'banned' });

    const result = validateDeck(
      [entry('Test Commander'), entry('Banned Card'), entry('Banned Card'), entry('Plains', 97)],
      nameMapOf([commander, plains(), banned]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.deepStrictEqual(result.legality.banned, ['Banned Card']);
  });

  it('banned lines that differ only by case are one card; distinct cards keep first-seen order', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });
    const bannedA = makeCard({ name: 'Banned A', legality_commander: 'banned' });
    const bannedB = makeCard({ name: 'Banned B', legality_commander: 'banned' });

    const result = validateDeck(
      [
        entry('Test Commander'),
        entry('Banned B'),
        entry('Banned A'),
        entry('banned b'),
        entry('Plains', 96),
      ],
      nameMapOf([commander, plains(), bannedA, bannedB]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.legality.banned.length, 2);
    assert.deepStrictEqual(
      result.legality.banned.map((n) => n.toLowerCase()),
      ['banned b', 'banned a'],
    );
  });

  it('an unresolvable name on several lines is reported once in notFound, all copies counted', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });

    const result = validateDeck(
      [
        entry('Test Commander'),
        entry('Not A Real Card'),
        entry('not a real card', 2),
        entry('Plains', 96),
      ],
      nameMapOf([commander, plains()]),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.deepStrictEqual(result.legality.notFound, ['Not A Real Card']);
    assert.strictEqual(result.isValid, false);
  });
});
