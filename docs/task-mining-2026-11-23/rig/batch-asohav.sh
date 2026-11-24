V=./verify.sh; A=asohavcompanionapp; S=apps/server; H=packages/shared
# 0.83.0 audit (f6dc24caf), one route + its test each
$V asohav-email-escape $A f6dc24caf $S "$S/src/email.test.ts" "$S/src/email.ts"
$V asohav-sheet-get-authz $A f6dc24caf $S "$S/src/routes/sheet.test.ts" "$S/src/routes/sheet.ts"
$V asohav-combat-end-authz $A f6dc24caf $S "$S/src/routes/combat.test.ts" "$S/src/routes/combat.ts"
$V asohav-library-id-immutable $A f6dc24caf $S "$S/src/routes/library.test.ts" "$S/src/routes/library.ts"
$V asohav-campaign-0830 $A f6dc24caf $S "$S/src/routes/campaign.test.ts" "$S/src/routes/campaign.ts"
# 0.86.0 audit (0f4a28142)
$V asohav-invite-redeem-cleanup $A 0f4a28142 $S "$S/src/routes/invites.test.ts" "$S/src/routes/invites.ts"
$V asohav-character-create-cleanup $A 0f4a28142 $S "$S/src/routes/characters.test.ts" "$S/src/routes/characters.ts"
$V asohav-auth-outage-503 $A 0f4a28142 $S "$S/src/supabase.test.ts" "$S/src/supabase.ts $S/src/auth.ts"
$V asohav-admin-changelog $A 0f4a28142 $S "$S/src/adminLogic.test.ts $S/src/routes/admin.test.ts" "$S/src/adminLogic.ts $S/src/routes/admin.ts"
$V asohav-motif-pad $A 0f4a28142 $H "$H/src/logic.test.ts" "$H/src/logic.ts $H/src/types.ts"
# 0.86.1 races (17209aef6)
$V asohav-invite-decline-pending $A 17209aef6 $S "$S/src/routes/invites.test.ts" "$S/src/routes/invites.ts"
$V asohav-campaign-phase-race $A 17209aef6 $S "$S/src/routes/campaign.test.ts" "$S/src/routes/campaign.ts"
# single commits
$V asohav-next-round-guard $A 55066ff3d $S "$S/src/routes/combat.test.ts" "$S/src/routes/combat.ts"
$V asohav-strain-clears-on-goal $A bd5a924ad $S "$S/src/routes/combat.test.ts" "$S/src/routes/combat.ts"
$V asohav-defaults-on-read $A 028a78563 $H "$H/src/logic.test.ts" "$H/src/logic.ts"
$V asohav-bond-spend-v07 $A cdd6eeb4b $H "$H/src/logic.test.ts" "$H/src/logic.ts"
