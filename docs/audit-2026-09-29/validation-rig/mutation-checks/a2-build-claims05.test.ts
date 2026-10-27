import { describe, expect, it, vi, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import type { Library } from '@asohav/shared';

/* library.ts was the only route file in the app with no tests at all until 0.50.0 — including
   POST /reset, which replaces every authored record in the live library with seed content and is
   reachable from one unconfirmed button in Content Admin. These cover the authorization surface,
   the CRUD paths, and the optimistic-locking precondition added in the same release. */
vi.mock('../repo.js', () => ({
  getLibrary: vi.fn(),
  getLibraryWithVersion: vi.fn(),
  saveLibrary: vi.fn(),
  appendChangeLog: vi.fn(),
  listChangeLog: vi.fn(),
}));

import * as repo from '../repo.js';
import { libraryRouter } from './library.js';
import { errorMiddleware } from '../errorMiddleware.js';

function appAs(isAdmin: boolean) {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    req.user = { id: 'u-mike', name: 'Mike', email: 'mike@asohav.dev', isAdmin };
    next();
  });
  app.use('/library', libraryRouter);
  // The real production error middleware, not a copy — LibraryConflictError reaches the client
  // through it rather than through an inline catch, so the harness needs it to see a 409.
  app.use(errorMiddleware);
  return app;
}

const VERSION = '2026-09-11T19:00:00.000+00:00';

function makeLibrary(overrides: Partial<Library> = {}): Library {
  return {
    virtues: [{ Id: 'v-might', Name: 'Might', Tagline: '', Essence: '', UsageHelperText: '' }],
    conditions: [], armorTypes: [], items: [], motifs: [], loadTiers: [],
    improvementTrees: [], improvements: [],
    moves: [{ Id: 'm-1', Name: 'Take a Risk', Kind: 'Basic', Description: '', Results: {} }],
    glossary: [], campAssets: [], enemies: [], villains: [], npcs: [], locations: [],
    settings: {},
    ...overrides,
  } as unknown as Library;
}

beforeEach(() => {
  vi.resetAllMocks();
  vi.mocked(repo.getLibrary).mockResolvedValue(makeLibrary());
  vi.mocked(repo.getLibraryWithVersion).mockResolvedValue({ library: makeLibrary(), version: VERSION });
  vi.mocked(repo.saveLibrary).mockResolvedValue('2026-09-11T19:05:00.000+00:00');
});


describe('prompt claims for asohav-05 (verified against the reference)', () => {
  const adm = () => request(appAs(true));
  // settings
  it.each([
    ['null for the boolean', { GlossaryAutoLink: null }, 400, /true or false/i],
    ['string for the boolean', { GlossaryAutoLink: 'yes' }, 400, /true or false/i],
    ['number for the boolean', { GlossaryAutoLink: 1 }, 400, /true or false/i],
    ['string for an int', { PotentialTrackLength: 'five' }, 400, undefined],
    ['null for an int', { PotentialTrackLength: null }, 400, undefined],
    ['boolean for an int', { PotentialTrackLength: true }, 400, undefined],
    ['9.5 for an int', { PotentialTrackLength: 9.5 }, 400, undefined],
    ['numeric string for an int', { PotentialTrackLength: '9' }, 400, undefined],
    ['unknown key', { PotentialTrackLenght: 5 }, 400, /unknown setting/i],
    ['unknown key alongside a valid one', { PotentialTrackLength: 6, Bogus: 1 }, 400, /unknown setting/i],
    ['negative integer', { ConditionFloor: -3 }, 200, undefined],
    ['zero', { PotentialTrackLength: 0 }, 200, undefined],
    ['huge integer (no range limit)', { PotentialTrackLength: 100000 }, 200, undefined],
    ['valid boolean', { GlossaryAutoLink: false }, 200, undefined],
    ['empty patch', {}, 200, undefined],
  ])('settings: %s', async (_n, body, status, msg) => {
    const res = await adm().put('/library/settings').send(body);
    expect(res.status).toBe(status);
    if (status === 400) {
      expect(res.body).toHaveProperty('error');
      expect(typeof res.body.error).toBe('string');
      if (msg) expect(res.body.error).toMatch(msg);
      expect(repo.saveLibrary).not.toHaveBeenCalled();
      expect(repo.appendChangeLog).not.toHaveBeenCalled();
    } else {
      expect(res.body.settings).toMatchObject(body);
      expect(repo.saveLibrary).toHaveBeenCalledTimes(1);
      expect(repo.appendChangeLog).toHaveBeenCalledTimes(1);
    }
  });

  // create
  it.each([
    ['missing Name', '/library/virtues', { Tagline: 'x' }],
    ['null Name', '/library/virtues', { Name: null }],
    ['empty Name', '/library/virtues', { Name: '' }],
    ['whitespace Name', '/library/virtues', { Name: '   \t ' }],
    ['missing required ref TreeId', '/library/improvements', { Name: 'X' }],
    ['missing required Definition', '/library/glossary', { Name: 'Term' }],
    ['missing required Results', '/library/moves', { Name: 'Move' }],
  ])('create refuses %s', async (_n, url, body) => {
    const res = await adm().post(url).send(body);
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/required/i);
    expect(repo.saveLibrary).not.toHaveBeenCalled();
    expect(repo.appendChangeLog).not.toHaveBeenCalled();
  });

  it('create applies every declared default when omitted', async () => {
    const items = await adm().post('/library/items').send({ Name: 'Lantern' });
    expect(items.status).toBe(200);
    expect(items.body.object).toMatchObject({ Name: 'Lantern', LoadCost: 1, Charges: 0 });
    const cond = await adm().post('/library/conditions').send({ Name: 'Dazed' });
    expect(cond.body.object.RollPenalty).toBe(-2);
    const asset = await adm().post('/library/campAssets').send({ Name: 'Wagon' });
    expect(asset.body.object.Tier).toBe(1);
  });
  it('create keeps a value the client sent, even a falsy one', async () => {
    const res = await adm().post('/library/items').send({ Name: 'Cloak', LoadCost: 0, Charges: 3 });
    expect(res.status).toBe(200);
    expect(res.body.object).toMatchObject({ LoadCost: 0, Charges: 3 });
  });
  it('create: the Id is generated with the collection prefix whatever the client sends', async () => {
    const res = await adm().post('/library/items').send({ Name: 'Rope', Id: 'i-injected' });
    expect(res.status).toBe(200);
    expect(res.body.object.Id).not.toBe('i-injected');
    expect(res.body.object.Id).toMatch(/^i-/);
    const saved = vi.mocked(repo.saveLibrary).mock.calls[0][0] as any;
    expect(saved.items.at(-1).Id).toBe(res.body.object.Id);
  });
  // update
  it('update: omitting a required field succeeds and keeps the stored value', async () => {
    const res = await adm().put('/library/virtues/v-might').send({ Tagline: 'Force' });
    expect(res.status).toBe(200);
    expect(res.body.object).toMatchObject({ Name: 'Might', Tagline: 'Force' });
    expect(repo.saveLibrary).toHaveBeenCalledTimes(1);
  });
  it.each([['empty', ''], ['whitespace', '  '], ['null', null]])('update: present %s Name is refused', async (_n, v) => {
    const res = await adm().put('/library/virtues/v-might').send({ Name: v });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/required/i);
    expect(repo.saveLibrary).not.toHaveBeenCalled();
    expect(repo.appendChangeLog).not.toHaveBeenCalled();
  });
  it('update does not apply defaults', async () => {
    vi.mocked(repo.getLibraryWithVersion).mockResolvedValue({ library: makeLibrary({ items: [{ Id: 'i-1', Name: 'Pack' }] as any }), version: VERSION });
    const res = await adm().put('/library/items/i-1').send({ Description: 'Big' });
    expect(res.status).toBe(200);
    expect(res.body.object).toEqual({ Id: 'i-1', Name: 'Pack', Description: 'Big' });
  });
  it('update with an unknown collection / record still 404s', async () => {
    expect((await adm().put('/library/sandwiches/x').send({ Name: 'a' })).status).toBe(404);
    expect((await adm().put('/library/virtues/v-nope').send({ Name: 'a' })).status).toBe(404);
  });
});
