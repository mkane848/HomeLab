#!/usr/bin/env python3
"""variants.py: wrong variants of each reference fix (exact text edits on the fixed source), run against the upstream tests."""
import json, os, re, subprocess
M = os.path.dirname(os.path.abspath(__file__))
from mutate import WT, E, sh  # noqa
V = {
 'lfc-09-digest-cutoff-watermark': [
  ('src/services/digest-state.ts', "lastDigestAt: sql`max(coalesce(${servers.lastDigestAt}, 0), ${timestamp})`", "lastDigestAt: timestamp", 'watermark may move back'),
  ('src/services/digest.ts', "advanceServerWatermark(server.id, cutoff);", "advanceServerWatermark(server.id, now());", 'advance to finish time'),
  ('src/services/digest.ts', "prepareDigestListings(server, cutoff)", "prepareDigestListings(server)", 'select up to now, not cutoff')],
 'lfc-10-sealed-sync-join': [
  ('src/services/sealed.ts', "inFlight ??= runSealedSync().finally(() => {\n    inFlight = null;\n  });", "inFlight ??= runSealedSync();", 'guard never cleared'),
  ('src/services/sealed.ts', "inFlight ??= runSealedSync().finally(() => {\n    inFlight = null;\n  });\n  return inFlight;", "inFlight ??= runSealedSync().finally(() => {\n    inFlight = null;\n  });\n  return inFlight.then((r) => r);", 'joins but returns a new promise')],
 'lfc-11-sealed-same-name': [
  ('src/services/sealed.ts', "const shown = name.length > room ? `${name.slice(0, room - 1)}…` : name;", "const shown = name;", 'no shortening'),
  ('src/services/sealed.ts', ".orderBy(sealedCache.name, sealedCache.setCode, sealedCache.uuid)", ".orderBy(sealedCache.name, sealedCache.uuid)", 'no set-code ordering')],
 'lfc-12-guild-lifecycle': [
  ('src/services/listing-expiry.ts', "  if (guildIds.length === 0) {\n    return 0;\n  }\n", "", 'empty cache marks everything'),
  ('src/services/digest-state.ts', "and(ne(servers.digestMode, 'disabled'), isNull(servers.removedAt))", "ne(servers.digestMode, 'disabled')", 'restart schedules left servers')],
 'asohav-14-strain-clears-on-goal': [
  ('apps/server/src/routes/combat.ts', "          : 'Combat ended — the Combat Goal was not achieved; Strain stays marked.' },", "          : 'Combat ended.' },", 'history text not updated')],
 'asohav-15-combat-end-authz': [
  ('apps/server/src/routes/combat.ts', "existing.Participants.filter((p) => p.Kind === 'PC' && ownCharacterIds.has(p.RefId)).map((p) => getSheet(p.RefId)),", "existing.Participants.filter((p) => p.Kind === 'PC').map((p) => getSheet(p.RefId)),", 'filter after reading (no filter)')],
 'asohav-16-sheet-get-authz': [
  ('apps/server/src/routes/sheet.ts', "if (!character || character.CampaignId !== campaign.Id)", "if (!character)", 'existence only, no campaign check')],
 'asohav-17-invite-email-escape': [
  ('apps/server/src/email.ts', "<strong>${escapeHtml(campaignName)}</strong>", "<strong>${campaignName}</strong>", 'escapeHtml exported but body not escaped'),
  ('apps/server/src/email.ts', "\"'\": '&#39;'", "\"'\": \"'\"", 'apostrophe not escaped')],
 'asohav-18-next-round-guard': [
  ('apps/server/src/routes/combat.ts', "!Number.isInteger(incoming.Round) || ", "", 'non-integer Round accepted'),
  ('apps/server/src/routes/combat.ts', "incoming.Round > existing.Round + 1", "incoming.Round > existing.Round + 2", 'jump of 2 accepted'),
  ('apps/server/src/routes/combat.ts', "res.status(409).json({ error: 'A Combat is already running in this campaign.' });", "res.status(409).json({ error: 'Conflict' });", 'other 409 message')],
 'asohav-19-defaults-on-read': [
  ('packages/shared/src/logic.ts', "Rapport: party.Rapport ?? 0,", "Rapport: party.Rapport || 0,", '|| instead of ??'),
  ('packages/shared/src/logic.ts', "    settings.PotentialTrackLength == null ||\n    settings.RapportTrackLength == null ||\n", "", 'backfill without the needs-normalizing check')],
 'asohav-20-motif-pad': [
  ('packages/shared/src/logic.ts', "  if (motifs.length >= 3) return motifs;\n", "  if (motifs.length >= 3) return motifs.slice(0, 3);\n", 'copies/truncates three or more'),
  ('packages/shared/src/logic.ts', "  if (motifs.length >= 3) return motifs;\n", "  if (motifs.length === 3) return motifs;\n  if (motifs.length > 3) return motifs.slice(0, 3);\n", 'truncates more than three')],
 'asohav-21-invite-decline-pending': [
  ('apps/server/src/routes/invites.ts', "    res.status(409).json({ error: 'This invite has already been used.' });", "    res.status(409).json({ error: 'Conflict.' });", 'other 409 message')],
}
for tid, vs in V.items():
    e = E[tid]; wt = os.path.join(M, 'wt', WT[tid]); td = os.path.join(wt, e['testDir'])
    base = sh(['git', 'rev-parse', 'HEAD'], wt).stdout.strip()
    print(f'== {tid}')
    for f, old, new, desc in vs:
        sh(['git', 'checkout', '-q', base, '--', '.'], wt)
        for k in ('src', 'tests'): sh(['git', 'apply', os.path.join(M, 'patches', f'{tid}.{k}.patch')], wt)
        p = os.path.join(wt, f); s = open(p, newline='').read()
        if s.count(old) != 1: print(f'  !! {desc}: old text found {s.count(old)} times'); continue
        open(p, 'w', newline='').write(s.replace(old, new))
        r = sh(['npx', 'vitest', 'run'] + e['testCmd'][3:], td)
        m = re.search(r'Tests\s+(.*)', re.sub(r'\x1b\[[0-9;]*m', '', r.stdout))
        print(f"  {desc}: {'GREEN (unpinned)' if r.returncode == 0 else 'red'} [{m.group(1).strip() if m else '?'}]")
    sh(['git', 'checkout', '-q', base, '--', '.'], wt); sh(['git', 'clean', '-qfd', '-e', 'node_modules'], wt)
