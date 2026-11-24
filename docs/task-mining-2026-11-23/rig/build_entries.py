#!/usr/bin/env python3
"""Build the manifest entries for the 13 tasks mined on 2026-11-23 (entries.json)."""
import json

LFC = "M:/Projects/LFCbot"
ASO = "M:/TTRPG/A Story of Heroes and Villains"
SERVER_ENV_NOTE = ("null = unset. Standing pin for the apps/server tasks. A model-written test that imports the real repo.ts "
                   "also imports pgPool.ts, which throws at import time unless DATABASE_URL is set (the route tests avoid it by "
                   "mocking the repo module with vi.mock). Unset is a clean checkout: the gates and the model's own shell see what "
                   "CI would.")
SHARED_SETUP = [{"note": "build @asohav/shared so the server package's workspace import resolves",
                 "cwd": "packages/shared", "cmd": ["npx", "tsc", "-p", "tsconfig.json"]}]
ACC_NOTE = "The upstream fix commit's own test files, swapped in over the model's and run against the model's source - informational, never a gate. "

LFC_INTRO = ("You are working in the lfc-bot repository: a Discord bot for trading Magic: The Gathering cards (and other games) "
             "between members of a server, with listings stored in SQLite through drizzle-orm. ")
MODELS = ("The repo checks its implicit state machines with a small model checker: each tests/models/*.model.test.ts is an "
          "abstraction of the code, with a conformance test that replays short traces against the real services and one test "
          "per invariant. A bug it found is kept as an `it.fails` test (an expected failure) there and as a repro in the "
          "matching ordinary test file, to be flipped to `it` by the change that fixes it. ")
MODEL_RULE = ("With your fix, flip every `it.fails` whose bug you fixed to `it` (an unexpected pass is a failure in vitest), update "
              "the model so the conformance test matches the fixed code, and where a test lists the expected shortest "
              "counterexamples, drop the ones that no longer exist. Bugs you were not asked to fix stay `it.fails`. ")
ASO_INTRO = ("You are working in the ASoHaVCompanionApp repository (A Story of Heroes and Villains), a tabletop RPG companion app "
             "for a Powered-by-the-Apocalypse game: an Express server in apps/server, a React client in apps/web and a shared "
             "rules package in packages/shared. ")
ROUTE_TESTS = ("The route tests mock the whole repo module with vi.mock('../repo.js', () => ({ ... })) and drive the router "
               "with supertest; a repo function the route starts calling must be added to that mock factory, or it is "
               "undefined in the test. ")


def tail(files, run, cwd=None):
    where = f" from {cwd}" if cwd else ""
    return (f"Your added/updated tests must FAIL if only your source change is reverted while the test changes stay. "
            f"Change ONLY these files: {', '.join(files)}. Do not commit. Do not touch any other file. "
            f"When done, run `{run}`{where} and make sure it passes.")


def lfc(id, title, source, base, fix, slug, src, tests, baseline, prompt, acc_note):
    return {
        "id": id, "title": title, "source": source, "repo": LFC, "branch": f"bench/{slug}",
        "benchBaseCommit": base, "packageManager": "npm",
        "baselineExpect": {"testsTotal": baseline, "testsPass": baseline},
        "allowFiles": src + tests, "srcRevertFiles": src, "testDir": ".",
        "testCmd": ["npx", "vitest", "run"] + tests, "installFlags": ["--ignore-scripts"],
        "acceptance": {"note": ACC_NOTE + acc_note, "ref": "upstream-fix", "commit": fix, "files": tests},
        "prompt": prompt + tail(src + tests, "npx vitest run " + " ".join(tests)),
    }


def aso(id, title, source, base, fix, slug, src, tests, baseline, prompt, acc_note, shared=False):
    td = "packages/shared" if shared else "apps/server"
    rel = [t[len(td) + 1:] for t in tests]
    e = {
        "id": id, "title": title, "source": source, "repo": ASO, "branch": f"bench/{slug}",
        "benchBaseCommit": base, "packageManager": "npm",
        "baselineExpect": {"testsTotal": baseline, "testsPass": baseline},
        "allowFiles": src + tests, "srcRevertFiles": src, "testDir": td,
        "testCmd": ["npx", "vitest", "run"] + rel, "installFlags": ["--ignore-scripts"],
    }
    if not shared:
        e["testEnv"] = {"DATABASE_URL": None}
        e["testEnvNote"] = SERVER_ENV_NOTE
        e["setup"] = SHARED_SETUP
    if acc_note is not None:
        e["acceptance"] = {"note": ACC_NOTE + acc_note, "ref": "upstream-fix", "commit": fix, "files": tests}
    e["prompt"] = prompt + tail(src + tests, "npx vitest run " + " ".join(rel), td)
    return e


def mined(repo, fix, date, subject, scope, numbers):
    return (f"Mined 2026-11-23 from {repo} commit {fix} ({date}, '{subject}'), {scope}. {numbers} "
            "Checked in a fresh worktree at the parent: baseline green, the fix commit's tests alone red against the unfixed "
            "source, green with the fix; identical over three repeats and under TZ=Pacific/Auckland; the whole package suite "
            "stays green with the fix (docs/task-mining-2026-11-23/).")


E = []

# ---------------------------------------------------------------- lfc-bot
E.append(lfc(
    "lfc-08-ready-clears-removal",
    "lfc-bot: a guild that re-added the bot while it was offline must not stay marked for removal",
    mined("lfc-bot", "758df9397a62b3560f464b461d55bb35d123a4cc", "2026-11-20", "Fix the two data-loss bugs the state-machine models found",
          "scoped to the first of its two bugs: src/events/ready.ts (a one-line call to the existing clearRemovalMarker) and its tests in tests/events/ready.test.ts and tests/models/server.model.test.ts; the digest-watermark half is lfc-09",
          "14/14 at the parent; the fix's tests alone 2 red of 14; 14/14 with the fix. A source-only fix is red too: the it.fails repros it fixes pass unexpectedly."),
    "8bdcd4d009a23cd9041f3e675b0b28bebb30512e", "758df9397a62b3560f464b461d55bb35d123a4cc", "ready-clears-removal",
    ["src/events/ready.ts"], ["tests/events/ready.test.ts", "tests/models/server.model.test.ts"], 14,
    LFC_INTRO + MODELS +
    "A server row has a removed_at marker: handleGuildDelete (src/events/guildDelete.ts) sets it when the bot is removed from a "
    "guild, handleGuildCreate (src/events/guildCreate.ts) clears it with clearRemovalMarker from src/services/listing-expiry.ts "
    "when the bot is added again, and an hourly retention purge deletes every server, with its listings, that has been marked for "
    "30 days. Discord does not replay gateway events the bot missed while it was offline, so a guild that removed and then "
    "re-added the bot during downtime sends no guildCreate. There is a data-loss bug: handleReady in src/events/ready.ts (run at "
    "every boot) upserts a config row for every guild in client.guilds.cache but never clears a removal marker, so such a guild "
    "stays marked and the purge deletes a live server's listings 30 days later. Fix handleReady so that: (1) every guild in the "
    "cache has its removal marker cleared at boot, using the existing clearRemovalMarker; (2) everything else it does at boot is "
    "unchanged (the config upsert, the expiry pass, the digest scheduling, the catalog warm-ups). This bug already has repros: "
    "an `it.fails` in tests/events/ready.test.ts ('clears the removal marker of a guild that re-added the bot while it was "
    "offline') and two in tests/models/server.model.test.ts (the member-not-marked and never-purge-a-member invariants). "
    + MODEL_RULE +
    "The guild that removed the bot while it was offline (the opposite case) is a different bug: leave its `it.fails` tests alone. ",
    "Upstream flips three it.fails to it, changes the model's boot transition to clear the marker of every member guild, and "
    "drops two entries from the shortest-counterexample map; the map test pins exactly which counterexamples remain, so a fix "
    "that also changed other boot behaviour shows up there."))

E.append(lfc(
    "lfc-09-digest-cutoff-watermark",
    "lfc-bot: a listing posted while a digest is being sent must appear in the next digest",
    mined("lfc-bot", "758df9397a62b3560f464b461d55bb35d123a4cc", "2026-11-20", "Fix the two data-loss bugs the state-machine models found",
          "scoped to the second of its two bugs: src/services/digest.ts and src/services/digest-state.ts with tests/services/digest.test.ts, tests/services/digest-state.test.ts and tests/models/digest.model.test.ts; the removal-marker half is lfc-08",
          "35/35 at the parent; the fix's tests alone 5 red of 38; 38/38 with the fix; source-only red (the model's conformance test and a flipped repro)."),
    "8bdcd4d009a23cd9041f3e675b0b28bebb30512e", "758df9397a62b3560f464b461d55bb35d123a4cc", "digest-cutoff-watermark",
    ["src/services/digest.ts", "src/services/digest-state.ts"],
    ["tests/services/digest.test.ts", "tests/services/digest-state.test.ts", "tests/models/digest.model.test.ts"], 35,
    LFC_INTRO + MODELS +
    "Each server gets a daily digest of new listings. A server row's lastDigestAt is the digest watermark. In "
    "src/services/digest.ts, runDigest(client, server, trigger) selects the listings to send with prepareDigestListings(server) "
    "from src/services/digest-state.ts (active listings created from lastDigestAt up to now()), delivers them (retries back off in "
    "real time, so this can take seconds), and on success calls setServerWatermark(server.id, "
    "now()). There is a data-loss bug: the watermark is set to when delivery FINISHED, so a listing created after the selection "
    "ran but before delivery finished is past the new watermark and never appears in any digest. Also, two overlapping runs "
    "(scheduled and /admin digest) can move the watermark backwards. Fix it so "
    "that: (1) prepareDigestListings takes an optional second parameter, prepareDigestListings(server: ServerRow, cutoff: number "
    "= now()), and selects only listings created at or before cutoff (still from lastDigestAt, inclusive, as today); (2) "
    "digest-state.ts exports a new advanceServerWatermark(serverId: string, timestamp: number): void that moves lastDigestAt "
    "forward to timestamp but never back (advancing to 2000 and then to 1000 leaves 2000) and sets it when it was never set "
    "(null); keep setServerWatermark as it is, other code uses it; (3) runDigest captures the cutoff (now()) once before "
    "selecting, passes it to prepareDigestListings, and on success calls advanceServerWatermark(server.id, cutoff) instead of "
    "setting the watermark to the finish time; (4) the returned DigestResult, the retries, the alert on total failure and the "
    "message splitting stay exactly as they are. The repros are an `it.fails` in tests/services/digest.test.ts ('puts a listing "
    "posted while a digest is being sent into the next digest') and the no-listing-lost invariant in "
    "tests/models/digest.model.test.ts. " + MODEL_RULE +
    "The model's runs will need to remember when each one started. Add tests in tests/services/digest-state.test.ts for (1) and "
    "(2). ",
    "Upstream imports advanceServerWatermark from digest-state.ts and calls prepareDigestListings(server, cutoff), so the prompt "
    "pins both signatures and the forward-only rule; the model test pins the run shape only through its conformance replay."))

E.append(lfc(
    "lfc-10-sealed-sync-join",
    "lfc-bot: a second sealed-catalog sync must join the one already running instead of downloading again",
    mined("lfc-bot", "605ad399b745d8753db46c3e9e811a10e6c7ad75", "2026-11-21", "Join a second sealed catalog sync to the one in flight",
          "used as is: src/services/sealed.ts with tests/services/sealed.test.ts and tests/models/catalog-sync.model.test.ts",
          "34/34 at the parent; the fix's tests alone 1 red of 35; 35/35 with the fix. The test the fix adds to sealed.test.ts passes on the unfixed code too, so the flipped model repro is what pins the bug."),
    "660f3265acdb07dd53c6f05e9ddd9d0215b30b4a", "605ad399b745d8753db46c3e9e811a10e6c7ad75", "sealed-sync-join",
    ["src/services/sealed.ts"], ["tests/services/sealed.test.ts", "tests/models/catalog-sync.model.test.ts"], 34,
    LFC_INTRO + MODELS +
    "src/services/sealed.ts keeps a local catalog of sealed products (booster boxes, bundles, decks) from MTGJSON: "
    "syncSealedCatalog() downloads an 11.6 MB set list, imports it in a transaction and resolves to { imported, removed }; it "
    "never throws. It runs from the boot warm-up and from a 16:00 UTC cron, which can ask at the same moment. There is a bug: "
    "syncSealedCatalog has no in-flight guard, so two calls that overlap run two downloads side by side (the catalog stays "
    "intact, the download is wasted). syncPokemonCatalog in src/services/tcgcsv.ts already solves this with an "
    "inFlight promise. Fix syncSealedCatalog so that: (1) a call made while a sync is running returns that run's promise - the "
    "very same Promise object, so `syncSealedCatalog() === syncSealedCatalog()` while the first is in flight - and starts no "
    "second download; (2) once a run has settled, the next call starts a fresh run (two awaited calls one after the other each "
    "fetch the catalog's metadata); (3) a failed run still resolves as today and does not leave the guard stuck; (4) the result "
    "shape and everything the sync does are unchanged. The repros are `it.fails` tests in "
    "tests/models/catalog-sync.model.test.ts, including 'a second sealed start joins the first run'. " + MODEL_RULE +
    "The model file keeps a non-joining variant of the sync as a control that the checker still catches the bug, if you need "
    "one; the Pokemon sync's tests there show the pattern. Add a test in tests/services/sealed.test.ts for (2). ",
    "Upstream asserts promise identity (second toBe first) and two metadata fetches for two sequential awaited calls; the "
    "prompt states both."))

E.append(lfc(
    "lfc-11-sealed-same-name",
    "lfc-bot: same-named sealed products must be told apart in autocomplete and each pick must resolve to its own product",
    mined("lfc-bot", "6a97d8375184c31c6b3d4e624c40c883ce5d4662", "2026-09-29", "fix(sealed): tell same-named products apart and resolve the one picked",
          "the four source files (src/services/sealed.ts, src/utils/constants.ts, src/commands/user/have-sealed.ts, src/commands/user/want-sealed.ts) with their three test files; AGENTS.md, CHANGELOG.md and docs/FAQ.md dropped",
          "46/46 at the parent; the fix's tests alone 8 red of 52; 52/52 with the fix. A spec reversal: three existing tests encode name-as-value, so a source-only fix is red."),
    "2e0e833f548156c60aea5299cde35f5446f642e2", "6a97d8375184c31c6b3d4e624c40c883ce5d4662", "sealed-same-name",
    ["src/services/sealed.ts", "src/utils/constants.ts", "src/commands/user/have-sealed.ts", "src/commands/user/want-sealed.ts"],
    ["tests/services/sealed.test.ts", "tests/commands/user/have-sealed.test.ts", "tests/commands/user/want-sealed.test.ts"], 46,
    LFC_INTRO +
    "The /have-sealed and /want-sealed commands post a listing for a sealed product (a booster box, a bundle, a Commander deck) "
    "picked through Discord autocomplete. In src/services/sealed.ts, autocompleteSealedProducts(query) returns up to 25 choices "
    "{ name, value } from the local catalog (sealed_cache rows with uuid, name, setCode), today with value equal to name; the "
    "command then calls resolveSealedProduct(productName, { setCode }) which looks for an exact name_normalized match, scoped by "
    "the set option when given. Discord caps a choice's name and value at 100 characters (SEALED_PRODUCT_NAME_MAX in "
    "src/utils/constants.ts). There is a bug: MTGJSON lists some products more than once under the same name (a Commander deck "
    "under both its main set FRA and its Commander set FRC), so autocomplete shows identical entries and every pick resolves to "
    "whichever copy sorts first by uuid, possibly with the wrong set and Mana Pool link. Fix it so that: (1) each choice's name "
    "is the product name followed by a space and its set code in parentheses, e.g. 'Bloomburrow Bundle (BLB)'; when that would "
    "exceed 100 characters the name part is shortened and ends in the single character U+2026 (horizontal ellipsis) so the whole label is exactly 100 "
    "characters and still ends with ' (SET)'; (2) each choice's value is 'uuid:' followed by the product's uuid, e.g. "
    "'uuid:fra-deck'; (3) choices are ordered by name, then set code, then uuid; (4) resolveSealedProduct given a 'uuid:<uuid>' "
    "value resolves exactly that product by uuid, whatever options.setCode says, and still enriches it as today; for a uuid that "
    "is no longer in the catalog it returns an unresolved result (resolved: false, uuid: null) and makes no Mana Pool call; a "
    "typed name (anything not starting with 'uuid:') resolves by name as today, scoped by the set option; (5) /have-sealed and "
    "/want-sealed, when the product came back unresolved and the input was a 'uuid:' value, reply with an error through the "
    "existing replyError helper (src/utils/replies.ts), whose message contains 'no longer in the catalog', and post no listing "
    "(no followUp, nothing inserted) - a typed name that does not resolve keeps today's behaviour. Some existing tests in "
    "tests/services/sealed.test.ts expect value to mirror name: that behaviour is being changed on purpose, so update them. Add "
    "tests for (1) to (5). ",
    "The upstream tests assert exact choice arrays (label and 'uuid:' value), the 100-character cut ending in U+2026 and ' (SET)', resolution "
    "by uuid against a different set option, no Mana Pool call for a vanished uuid, and the 'no longer in the catalog' reply; "
    "the prompt pins each."))

E.append(lfc(
    "lfc-12-guild-lifecycle",
    "lfc-bot: each server's digest job must follow whether the bot is in it (rejoin, restart, and removal while offline)",
    mined("lfc-bot", "af2a8e640fb382707c319d9f29cddfa1cd44c262", "2026-11-21", "Keep each server's digest job in step with whether the bot is in it",
          "used as is: src/events/guildCreate.ts, src/events/ready.ts, src/services/digest-state.ts and src/services/listing-expiry.ts with four test files. The rejoin fix alone was the owner's first pick, but it turns the server model's conformance test red in the full suite (1 of 857), so the whole commit is the task (owner, 2026-11-23)",
          "35/35 at the parent; the fix's tests alone 4 red of 36; 36/36 with the fix; source-only red (three repros and the conformance test)."),
    "cb2338c3f8248a8f4880e4cc3e119fc1f23a1733", "af2a8e640fb382707c319d9f29cddfa1cd44c262", "guild-lifecycle",
    ["src/events/guildCreate.ts", "src/events/ready.ts", "src/services/digest-state.ts", "src/services/listing-expiry.ts"],
    ["tests/events/guildCreate.test.ts", "tests/events/ready.test.ts", "tests/models/server.model.test.ts", "tests/services/scheduler.test.ts"], 35,
    LFC_INTRO + MODELS +
    "Each server with digests on has a cron job (src/services/scheduler.ts: scheduleAllDigests at boot, "
    "refreshServerDigest(client, serverId) to create or update one). A server row's removed_at "
    "marker is set by handleGuildDelete (which also cancels the job) and cleared by handleGuildCreate; Discord does not replay "
    "events the bot missed while offline. The server "
    "model found three gaps: (a) rejoining does not restore the digest - handleGuildCreate in src/events/guildCreate.ts clears "
    "the marker and upserts the config but never recreates the job, so digests stop until a restart; (b) a restart "
    "schedules digests for servers the bot has left - listScheduledServers in src/services/digest-state.ts selects on "
    "digest_mode alone; (c) a guild that removed the bot while it was offline is never marked, because no guildDelete arrives "
    "for it. Fix all three so that: (1) handleGuildCreate also calls refreshServerDigest(guild.client, guild.id) (a new guild's "
    "digest is off, so that creates no job); (2) listScheduledServers returns only servers whose digest mode is not 'disabled' "
    "AND whose removed_at is null; (3) src/services/listing-expiry.ts exports markServersNotIn(guildIds: readonly string[]): "
    "number, which sets removed_at (and updatedAt) to now on every unmarked server whose id is not in guildIds and returns how "
    "many it marked; an empty list marks nothing and returns 0 (at boot an empty cache is likely a cache problem); (4) handleReady in src/events/ready.ts calls "
    "markServersNotIn with the ids of every guild in client.guilds.cache, after clearing the markers of the guilds it is in and "
    "before scheduling digests, and otherwise boots as today. The repros are `it.fails` tests in the four test files. " + MODEL_RULE +
    "With all three fixed the server model finds no violation; its conformance replay runs the real handlers, so give "
    "its fake client one other guild so the empty-cache rule does not apply there. Add a test "
    "for the empty-cache rule. ",
    "The upstream tests drive the real handlers and the model; the empty-cache rule is pinned through handleReady with an "
    "empty cache, and the model test asserts no violation remains."))

# ---------------------------------------------------------------- ASoHaV
E.append(aso(
    "asohav-14-strain-clears-on-goal",
    "ASoHaVCompanionApp: ending Combat must clear the Heroes' Strain only when the Combat Goal was achieved",
    mined("ASoHaVCompanionApp", "bd5a924ad1976695b7fba11afc02c1b4b4e97ed3", "2026-10-18", "Ending Combat: Strain clears only when the Combat Goal is achieved (0.70.0)",
          "scoped to the server half: apps/server/src/routes/combat.ts with apps/server/src/routes/combat.test.ts (the web files, docs and release edits dropped)",
          "20/20 at the parent; the fix's tests alone 1 red of 22; 22/22 with the fix. A ruleset change landing as a fix that reverses asohav-08's behaviour: the existing test that expects Strain to clear on every end must be updated, so a source-only fix is red."),
    "c761a356b27fff4489032e1153b84f270d02996a", "bd5a924ad1976695b7fba11afc02c1b4b4e97ed3", "strain-clears-on-goal",
    ["apps/server/src/routes/combat.ts"], ["apps/server/src/routes/combat.test.ts"], 20,
    ASO_INTRO + ROUTE_TESTS +
    "The GM runs each fight as a Combat Encounter record: Participants (Kind 'PC' for a Hero, whose RefId is that Hero's "
    "character id, or Kind 'Enemy'), a Status of 'Active' or 'Ended', a History log of { Id, At, Text } entries (newest first) "
    "and a boolean CombatGoalAchieved that the table sets during the fight. A Hero's Strain lives on the Hero's own character "
    "sheet: CharacterSheet.Strain is an array of booleans, true meaning marked. In apps/server/src/routes/combat.ts, POST "
    "/campaigns/:campaignId/combat/:encounterId/end (GM only) ends the fight: it sets Status 'Ended', loads each Hero "
    "participant's sheet with getSheet(RefId), saves every sheet that has Strain marked with all of it cleared via "
    "saveSheet(sheet, campaignId), and adds a History entry saying Combat ended and every Hero's Strain is cleared. The ruleset "
    "changed (V0.7, 'Ending Combat'): Strain clears only when the Heroes achieved the Combat Goal; when they failed it they "
    "concede and Strain stays marked. Change the route so that: (1) when the Encounter's CombatGoalAchieved is true it clears "
    "Strain exactly as today (same sheets read, only sheets with marked Strain saved, the same saveSheet call shape); (2) when "
    "it is false (or missing) it reads and saves no sheet at all; (3) the History entry says which: when achieved its Text "
    "contains 'the Combat Goal was achieved' and that every Hero's Strain is cleared, and when not achieved its Text contains "
    "'Strain stays marked'; (4) authorization, the 404s, the Status change and the response shape are unchanged. The existing "
    "test 'clears every Hero's marked Strain when Combat ends' assumes the old rule: update it so its Encounter has "
    "CombatGoalAchieved: true rather than deleting it. Add tests for (1), (2) and (3). ",
    "It mocks getCampaign, membershipFor, listEncountersForCampaign and getSheet, and asserts saveSheet calls and the History "
    "text /Strain stays marked/; the prompt pins the field and the text."))

E.append(aso(
    "asohav-15-combat-end-authz",
    "ASoHaVCompanionApp: ending Combat must never read or write the sheet of a character from another campaign",
    mined("ASoHaVCompanionApp", "f6dc24caf207108ccf963c4e729f19e2d6d50b39", "2026-11-14", "0.83.0: audit and code review fixes, with the report",
          "a nine-item audit commit scoped to one finding: apps/server/src/routes/combat.ts with apps/server/src/routes/combat.test.ts",
          "30/30 at the parent; the fix's tests alone 1 red of 31; 31/31 with the fix. Source-only is red in two existing tests: the route starts calling listCharacters, which the test file's repo mock does not provide."),
    "0bf6052ba9cc74e4d6684f2e6b960d9d992c3297", "f6dc24caf207108ccf963c4e729f19e2d6d50b39", "combat-end-authz",
    ["apps/server/src/routes/combat.ts"], ["apps/server/src/routes/combat.test.ts"], 30,
    ASO_INTRO + ROUTE_TESTS +
    "The GM runs each fight as a Combat Encounter record whose Participants are { Id, Kind, RefId }: Kind 'PC' is a Hero and "
    "RefId is that Hero's character id. The Encounter is saved whole by PUT /campaigns/:campaignId/combat/:encounterId, which "
    "any campaign member may call, so a Participant's RefId is whatever a member sent. In apps/server/src/routes/combat.ts, POST "
    "/campaigns/:campaignId/combat/:encounterId/end (GM only) ends the fight and, when the Combat Goal was achieved, loads each "
    "PC participant's sheet with getSheet(RefId) and saves those with Strain marked through saveSheet(sheet, campaignId), which "
    "also writes the sheet's campaign_id. There is a security bug: the route trusts RefId, so a member who puts another "
    "campaign's character id in the Encounter makes the GM's end clear that foreign Hero's Strain and re-home its sheet row to "
    "this campaign. Fix the route so that: (1) it gets this campaign's characters once with listCharacters(campaign.Id) from "
    "the repo module (already exported; it resolves to Character objects with an Id) and only PC participants whose RefId is "
    "one of those ids have their sheet read and saved; (2) a participant whose RefId is not in this campaign is skipped "
    "silently - getSheet is never called for it, nothing is saved for it, and the end still answers 200; (3) everything else "
    "about ending Combat is unchanged. Add listCharacters to the test file's repo mock (with a default that returns this "
    "campaign's characters, so the existing end tests keep passing) and add a test for (2). ",
    "It mocks listCharacters to resolve [{ Id: 'ch-1' }, { Id: 'ch-2' }] and asserts that a foreign RefId gets no getSheet and "
    "no saveSheet call; the prompt pins listCharacters(campaign.Id)."))

E.append(aso(
    "asohav-16-sheet-get-authz",
    "ASoHaVCompanionApp: a GM must not read the sheet of a character from another campaign",
    mined("ASoHaVCompanionApp", "f6dc24caf207108ccf963c4e729f19e2d6d50b39", "2026-11-14", "0.83.0: audit and code review fixes, with the report",
          "a nine-item audit commit scoped to one finding: apps/server/src/routes/sheet.ts with apps/server/src/routes/sheet.test.ts",
          "9/9 at the parent; the fix's tests alone 1 red of 11; 11/11 with the fix."),
    "0bf6052ba9cc74e4d6684f2e6b960d9d992c3297", "f6dc24caf207108ccf963c4e729f19e2d6d50b39", "sheet-get-authz",
    ["apps/server/src/routes/sheet.ts"], ["apps/server/src/routes/sheet.test.ts"], 9,
    ASO_INTRO + ROUTE_TESTS +
    "A campaign has one GM and players; each player's Hero is a character (Character: Id, CampaignId, ...) with a character "
    "sheet. In apps/server/src/routes/sheet.ts, GET /campaigns/:campaignId/sheets/:characterId returns a sheet: it loads the "
    "campaign from the URL, checks the caller's membership, lets the GM of that campaign read any sheet, and lets a player "
    "read their own. There is a security bug: anyone can create a campaign and so be a GM, and the route only checks that the "
    "caller is the GM of the campaign IN THE URL, never that the character belongs to that campaign, so any account can read "
    "any character's sheet by id. Fix the route so that: (1) it loads the character with getCharacter(characterId) from the "
    "repo module (already exported and already in the test file's mock) and, when there is no such character or its "
    "CampaignId is not this campaign's Id, answers 404 with a JSON error and does not read the sheet (getSheet is never called); "
    "(2) a GM reading a sheet of a character in their own campaign still gets 200 with the sheet; (3) the player rules, the "
    "other 404s and 403s, and the PUT routes are unchanged. Add tests for (1) and (2). ",
    "It mocks getCharacter to return a character of 'cm-other' and asserts 404 and no getSheet call; the prompt pins getCharacter "
    "and the 404."))

E.append(aso(
    "asohav-17-invite-email-escape",
    "ASoHaVCompanionApp: the GM-typed campaign name must be HTML-escaped in invite emails",
    mined("ASoHaVCompanionApp", "f6dc24caf207108ccf963c4e729f19e2d6d50b39", "2026-11-14", "0.83.0: audit and code review fixes, with the report",
          "a nine-item audit commit scoped to one finding: apps/server/src/email.ts with apps/server/src/email.test.ts",
          "8/8 at the parent; the fix's tests alone 1 red of 9; 9/9 with the fix."),
    "0bf6052ba9cc74e4d6684f2e6b960d9d992c3297", "f6dc24caf207108ccf963c4e729f19e2d6d50b39", "invite-email-escape",
    ["apps/server/src/email.ts"], ["apps/server/src/email.test.ts"], 8,
    ASO_INTRO +
    "apps/server/src/email.ts sends campaign invite emails: sendViaResend builds an HTML body, '<p>You've been invited to join "
    "<strong>${campaignName}</strong> on ASoHaV Companion.</p>' plus a paragraph with a link to the invite and the invite code, "
    "and a subject \"You're invited to ${campaignName}\". There is a security bug: the campaign name is whatever its GM typed, "
    "and it goes unescaped into an HTML email sent from this app's own domain to an address the GM chose, so a GM can mail "
    "arbitrary markup (a convincing link, say) to any account holder. Fix email.ts so that: (1) it exports a function "
    "escapeHtml(text: string): string that replaces each of the five characters & < > \" ' with &amp; &lt; &gt; &quot; &#39; "
    "respectively and leaves everything else as is (escapeHtml('<a href=\"x\">&\\'</a>') returns "
    "'&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;'); (2) the HTML body passes the campaign name, the link and the code "
    "through escapeHtml; (3) the subject, which is plain text, has any run of line breaks replaced by a single space and is "
    "kept to a sensible length; (4) how and where the email is sent is unchanged. Add tests in apps/server/src/email.test.ts for (1) "
    "and (2). ",
    "It imports escapeHtml from './email.js' and asserts its exact output for one string; the prompt pins the name and the "
    "mapping. The body and subject parts are not covered by the upstream test."))

E.append(aso(
    "asohav-18-next-round-guard",
    "ASoHaVCompanionApp: a second simultaneous Start Combat must answer 409, and an Encounter save must not move Round out of step",
    mined("ASoHaVCompanionApp", "55066ff3deb7cb66d8e86abca67a8bcb0a314e40", "2026-10-24", "Close the Start Combat race at the database; guard Next Round",
          "scoped to the route: apps/server/src/routes/combat.ts with apps/server/src/routes/combat.test.ts (the migration adding the partial unique index and repo.ts dropped)",
          "22/22 at the parent; the fix's tests alone 4 red of 30; 30/30 with the fix."),
    "4b63a80a9cc563f363eac28926b042568a2d8ca2", "55066ff3deb7cb66d8e86abca67a8bcb0a314e40", "next-round-guard",
    ["apps/server/src/routes/combat.ts"], ["apps/server/src/routes/combat.test.ts"], 22,
    ASO_INTRO + ROUTE_TESTS +
    "The GM runs each fight as a Combat Encounter (Status 'Active' or 'Ended', a Round counter starting at 1, ...). In "
    "apps/server/src/routes/combat.ts: POST /campaigns/:campaignId/combat/start checks with getActiveEncounter that no Combat "
    "is running, then saves a new Encounter with saveEncounter and updates the Party's Rapport with saveParty; PUT "
    "/campaigns/:campaignId/combat/:encounterId saves the whole Encounter (the request body merged over the stored one), and "
    "the client's 'Next Round' button uses it to send Round + 1. Two bugs: (a) the start check is a read-then-write, so two "
    "simultaneous Starts can both pass it; the database now has a partial unique index allowing one Active Encounter per "
    "campaign, so the loser's saveEncounter rejects with a Postgres unique violation, an error object whose code is '23505', "
    "and the route lets it become a 500; (b) the PUT accepts any Round, so a double-tap or a stale tab can skip or rewind "
    "rounds. Fix the routes so that: (1) on start, a saveEncounter rejection whose code is '23505' answers 409 with { error: "
    "'A Combat is already running in this campaign.' } and saves no Party (saveParty is not called); any other save failure "
    "still propagates as today (a 500); (2) on PUT, when the body's Round differs from the stored Round, it must be an integer "
    "equal to the stored Round + 1, otherwise answer 409 with a JSON error and save nothing (saveEncounter is not called): the "
    "same Round and Round + 1 are accepted, a lower Round, a jump of more than 1 and a non-integer are refused; a PUT that "
    "carries no Round, or the stored Round, is untouched by this rule; (3) everything else about both routes is unchanged. Add "
    "tests for (1) and (2). ",
    "It makes saveEncounter reject with { code: '23505', ... } and asserts the exact 409 message and no saveParty, a 500 for "
    "another code, and the Round cases; the prompt pins the code, the message and the rule."))

E.append(aso(
    "asohav-19-defaults-on-read",
    "ASoHaVCompanionApp: normalizers must default Armor, Rapport and two library track lengths that older rows lack",
    mined("ASoHaVCompanionApp", "028a78563c8e3fa949ae3c899635eb97d7fbf792", "2026-10-18", "0.67.1: default Armor, Rapport and two library track lengths on read",
          "scoped to packages/shared/src/logic.ts with packages/shared/src/logic.test.ts (version, docs and changelog edits dropped)",
          "160/160 at the parent; the fix's tests alone 3 red of 163; 163/163 with the fix. Three independent defaults in a 1,150-line file."),
    "42493a1531e8e3b01bb1706c35725b5b821ced24", "028a78563c8e3fa949ae3c899635eb97d7fbf792", "defaults-on-read",
    ["packages/shared/src/logic.ts"], ["packages/shared/src/logic.test.ts"], 160,
    ASO_INTRO +
    "packages/shared/src/logic.ts holds the pure rules helpers, including normalizers that the server runs on every row it "
    "reads so that documents saved by older versions get the fields the current code assumes: normalizeSheet(sheet, "
    "strainBoxes?) for a character sheet, normalizeParty(party) for the shared Party record, and normalizeLibrary(library) for "
    "the game library (whose settings object holds tunables). There is a bug: three fields added in later releases are not "
    "defaulted, so rows saved before them crash or misbehave: a sheet saved without Armor (an array the Armor panel and Make "
    "Camp read unguarded), a Party saved without Rapport (a number every writer increments, so it becomes NaN), and a library "
    "settings row without PotentialTrackLength or RapportTrackLength. Fix logic.ts so that: (1) normalizeSheet gives a sheet "
    "with no Armor an empty array and keeps a stored Armor list as is; (2) normalizeParty gives a Party with no Rapport 0 and "
    "keeps a stored value as is, including 0 and a value above the track length (banked Rapport is legal); (3) "
    "normalizeLibrary backfills settings.PotentialTrackLength and settings.RapportTrackLength to 5 when either is missing and "
    "keeps stored values, and when the settings already have both (and nothing else needs filling) it returns the very same "
    "settings object, as it does today for a complete row; (4) nothing else the normalizers do changes. The test file has "
    "makeSheet, seedParty and seedLibrary helpers. Add tests for (1), (2) and (3). ",
    "It deletes each field from a seeded object and asserts the default, keeps stored values, and asserts "
    "normalizeLibrary(custom).settings is the same object when complete; the prompt states the identity rule.",
    shared=True))

E.append(aso(
    "asohav-20-motif-pad",
    "ASoHaVCompanionApp: normalizeSheet must pad a short Motif list instead of replacing it with blanks",
    mined("ASoHaVCompanionApp", "0f4a2814295bef4573417fc15c98b95f9f514c96", "2026-11-17", "0.86.0: remaining audit items that need no owner decision",
          "a seven-item audit commit scoped to one finding: packages/shared/src/logic.ts with packages/shared/src/logic.test.ts (types.ts belongs to another finding)",
          "187/187 at the parent; the fix's tests alone 1 red of 189; 189/189 with the fix. One hunk in a 1,400-line file."),
    "208ec7ff7d011db1079dea55e440d9c1d9b5d4b6", "0f4a2814295bef4573417fc15c98b95f9f514c96", "motif-pad",
    ["packages/shared/src/logic.ts"], ["packages/shared/src/logic.test.ts"], 187,
    ASO_INTRO +
    "A Hero's character sheet has exactly three Motifs (the Hero's themes; emptyMotif() in packages/shared/src/logic.ts makes a "
    "blank one). normalizeSheet(sheet, strainBoxes?) in logic.ts makes stored sheets fit the current shape, and since 0.83.1 the "
    "server runs it on every save as well as every read. There is a data-loss bug: normalizeSheet keeps the Motifs only when "
    "there are exactly three; any other length - including a sheet carrying two real Motifs - is replaced by three blank ones, "
    "so a save with two Motifs wipes both. Fix normalizeSheet so that: (1) a Motif list shorter than three keeps its entries in "
    "order and is padded with blank Motifs (emptyMotif()) up to three; (2) a list of three or more is returned as the very same "
    "array, untouched (entries beyond three are kept: dropping a player's data is worse than showing it); (3) a missing or "
    "non-array Motifs still becomes three blank Motifs; (4) nothing else normalizeSheet does changes. The test file has a "
    "makeSheet(overrides) helper. Add tests for (1) and (2). ",
    "It asserts a two-Motif sheet keeps its first Motif and has three, and that a three-Motif array comes back as the same "
    "array (toBe); the prompt states the identity rule.",
    shared=True))

E.append(aso(
    "asohav-21-invite-decline-pending",
    "ASoHaVCompanionApp: declining an invite must only succeed while it is still Pending",
    mined("ASoHaVCompanionApp", "17209aef6d7343fc64bc0564e4b129012ce30104", "2026-11-20", "0.86.1: state transitions that two requests at once could break",
          "hand-scoped to one finding: the decline hunk of apps/server/src/routes/invites.ts and the decline tests of apps/server/src/routes/invites.test.ts. The same commit also changed the redemption rollback to a new repo function, releaseInviteClaim, that does not exist at the parent, so those hunks (one source, two test) are dropped",
          "14/14 at the parent; the scoped tests alone 2 red of 15; 15/15 with the scoped fix; source-only red in the existing decline test, which asserts the unconditional write."),
    "f0f6779b8ae729738761710d4fe22724f39e4b4d", "17209aef6d7343fc64bc0564e4b129012ce30104", "invite-decline-pending",
    ["apps/server/src/routes/invites.ts"], ["apps/server/src/routes/invites.test.ts"], 14,
    ASO_INTRO + ROUTE_TESTS +
    "An invite to a campaign has a Status: 'Pending', then 'Accepted' (redeemed) or 'Declined'. In "
    "apps/server/src/routes/invites.ts, redeeming already claims the invite atomically with claimPendingInvite(id, 'Accepted') "
    "from the repo module, which moves it to the given status only if it is still Pending and resolves to true, or false when "
    "another request moved it first. POST /invites/:id/decline, after checking the invite is addressed to the caller, writes "
    "unconditionally with updateInviteStatus(invite.Id, 'Declined'). There is a race: a decline that lands just after a "
    "redemption writes Declined over the Accepted invite, leaving a member whose invite reads Declined. Fix the decline route "
    "so that: (1) it declines with claimPendingInvite(invite.Id, 'Declined') instead of updateInviteStatus; (2) when that "
    "resolves to false it answers 409 with { error: 'This invite has already been used.' }; (3) when it resolves to true it "
    "answers 200 with { ok: true } as today; (4) the checks before it (the 404 for an unknown invite, the 403 for an invite "
    "addressed to someone else, which must not touch the invite) and the redeem routes are unchanged - leave redeem's own "
    "rollback, which still uses updateInviteStatus, as it is. The existing decline test expects the unconditional "
    "updateInviteStatus call: update it. Add a test for (2). ",
    None))

json.dump(E, open("entries.json", "w"), indent=1, ensure_ascii=False)
print(len(E), "entries")
for e in E:
    print(f"{e['id']:36} prompt {len(e['prompt']):5} chars  allow {len(e['allowFiles'])}  base {e['baselineExpect']['testsTotal']}")
