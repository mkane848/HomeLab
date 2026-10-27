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
      nameMapOf([commander, makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' })]),
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
      nameMapOf([commander, makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' })]),
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
        makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' }),
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
      nameMapOf([commander, makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' })]),
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
        makeCard({ name: 'Island', type_line: 'Basic Land — Island', color_identity: '["U"]' }),
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
      [entry('Test Commander'), entry('Wastes', 99)],
      nameMapOf([commander, makeCard({ name: 'Wastes', type_line: 'Basic Land', color_identity: '[]' })]),
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
      nameMapOf([notEligible, makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["U"]' })]),
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
        makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["U"]' }),
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
      nameMapOf([a, b, makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["U"]' })]),
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
      nameMapOf([chooser, makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' })]),
      [chooser],
      [background],
    );

    assert.strictEqual(result.commander.pairingLegal, true);
    assert.strictEqual(result.isValid, true);
  });
});
describe('validateDeck — singleton rule (903.5b)', () => {
  const solRing = () => makeCard({ name: 'Sol Ring', type_line: 'Artifact', color_identity: '[]' });

  /** A legal shell: one commander, `extra` cards, and enough basic Plains to reach exactly 100. */
  function validate(extra: ParsedListEntry[], extraCards: CardRow[]) {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });
    const plains = makeCard({
      name: 'Plains',
      type_line: 'Basic Land — Plains',
      color_identity: '["W"]',
    });
    const used = 1 + extra.reduce((sum, e) => sum + e.quantity, 0);
    return validateDeck(
      [entry('Test Commander'), ...extra, entry('Plains', 100 - used)],
      nameMapOf([commander, plains, ...extraCards]),
      [commander],
      [],
    );
  }

  it('two copies of a nonbasic card break the rule and invalidate the deck', () => {
    const result = validate([entry('Sol Ring', 2)], [solRing()]);

    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.deckSize.isValid, true);
    assert.strictEqual(result.isValid, false);
    assert.deepStrictEqual(result.singleton.violations, [
      { name: 'Sol Ring', quantity: 2, limit: 1 },
    ]);
  });

  it('the same card spread over several lines counts as several copies, however it is cased', () => {
    const result = validate([entry('Sol Ring'), entry('sol ring')], [solRing()]);

    assert.strictEqual(result.isValid, false);
    assert.deepStrictEqual(result.singleton.violations, [
      { name: 'Sol Ring', quantity: 2, limit: 1 },
    ]);
  });

  it('one copy of each nonbasic card is a legal singleton deck', () => {
    const other = makeCard({ name: 'Arcane Signet', type_line: 'Artifact' });
    const result = validate([entry('Sol Ring'), entry('Arcane Signet')], [solRing(), other]);

    assert.strictEqual(result.isValid, true);
  });

  it('basic lands are exempt at any quantity — plain, snow and Wastes alike', () => {
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["W"]' });
    const cards = [
      commander,
      makeCard({ name: 'Plains', type_line: 'Basic Land — Plains', color_identity: '["W"]' }),
      makeCard({
        name: 'Snow-Covered Plains',
        type_line: 'Basic Snow Land — Plains',
        color_identity: '["W"]',
      }),
      makeCard({ name: 'Wastes', type_line: 'Basic Land', color_identity: '[]' }),
    ];
    const result = validateDeck(
      [
        entry('Test Commander'),
        entry('Plains', 60),
        entry('Snow-Covered Plains', 30),
        entry('Wastes', 9),
      ],
      nameMapOf(cards),
      [commander],
      [],
    );

    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.isValid, true);
  });

  it('a nonbasic land with a basic land type is not exempt', () => {
    // Stomping Ground is "Land — Mountain Forest": it has basic land TYPES but is not
    // a basic land, so the exemption must key on the Basic supertype.
    const stomping = makeCard({
      name: 'Stomping Ground',
      type_line: 'Land — Mountain Forest',
      color_identity: '["R","G"]',
    });
    const commander = eligibleCommander({ name: 'Test Commander', color_identity: '["R","G"]' });
    const result = validateDeck(
      [entry('Test Commander'), entry('Stomping Ground', 2), entry('Mountain', 97)],
      nameMapOf([
        commander,
        stomping,
        makeCard({ name: 'Mountain', type_line: 'Basic Land — Mountain', color_identity: '["R"]' }),
      ]),
      [commander],
      [],
    );

    assert.strictEqual(result.isValid, false);
    assert.deepStrictEqual(result.singleton.violations, [
      { name: 'Stomping Ground', quantity: 2, limit: 1 },
    ]);
  });

  it('a card that says "any number of cards named" is exempt', () => {
    const rats = makeCard({
      name: 'Relentless Rats',
      type_line: 'Creature — Rat',
      oracle_text: 'Relentless Rats gets +1/+1 for each other Rat on the battlefield.\nA deck can have any number of cards named Relentless Rats.',
    });
    const result = validate([entry('Relentless Rats', 30)], [rats]);

    assert.strictEqual(result.deckSize.total, 100);
    assert.strictEqual(result.isValid, true);
  });

  it('an "up to N" card is allowed exactly N copies and reports its own limit beyond that', () => {
    const dwarves = () =>
      makeCard({
        name: 'Seven Dwarves',
        type_line: 'Creature — Dwarf',
        oracle_text: 'Seven Dwarves gets +1/+1 for each other creature named Seven Dwarves you control.\nA deck can have up to seven cards named Seven Dwarves.',
      });

    assert.strictEqual(validate([entry('Seven Dwarves', 7)], [dwarves()]).isValid, true);

    const over = validate([entry('Seven Dwarves', 8)], [dwarves()]);
    assert.strictEqual(over.isValid, false);
    assert.deepStrictEqual(over.singleton.violations, [
      { name: 'Seven Dwarves', quantity: 8, limit: 7 },
    ]);
  });

  it('a banned card listed twice is reported as banned, not as a singleton violation', () => {
    const banned = makeCard({ name: 'Banned Card', legality_commander: 'banned' });
    const result = validate([entry('Banned Card', 2)], [banned]);

    assert.strictEqual(result.isValid, false);
    assert.deepStrictEqual(result.singleton.violations, []);
    assert.ok(result.legality.banned.includes('Banned Card'));
  });
});
