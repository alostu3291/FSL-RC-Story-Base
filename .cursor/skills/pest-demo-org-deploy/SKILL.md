---
name: pest-demo-org-deploy
description: Deploys the Rentokil pest control / Field Service demo to an existing Salesforce org. Inventories what the org already has (check-only deploys per bundle plus data checks), pushes only what's missing or changed, runs the pest tests separately, and debugs known deploy failures. Use when deploying, updating or repairing the pest or FSL demo in an org, or when asked what an org is missing.
---

# Pest Demo Org Deploy

Bundles: `unpackaged/post_fsl`, `post_pest_sla`, `post_pest`, `post_pest_ai`,
`post_pest_docgen` and `post_pest_agent`, plus the pest UX templates
(`templates/*/pest`). The full build is the `prepare_pest` flow (after `prepare_fsl`).
Feature guide: `docs/guides/pest-control-demo.md`.

## Quick Rules

1. Inventory first, deploy second. Never redeploy blind into a demo org in use.
2. `cci` takes the CCI alias; `sf` takes the username or sf alias. Get both from `cci org list`.
3. `cci task run X` ignores feature flags; only flow steps check `when:`. Single tasks are
   the safe way to patch an existing org.
4. Some orgs skip Apex tests on deploy. Always run the pest tests afterwards (step 5).
5. A deploy is done when the live check passes, not when the CLI says Succeeded.
6. For the Field Service mobile app in an org created from Winter '27 on, turn on **Require
   Proof Key for Code Exchange (PKCE) Extension for Supported Authorization Flows** (Setup →
   OAuth and OpenID Connect Settings). Without it the iOS app fails with
   `oauth_approval_error_generic`, because Allow OAuth User-Agent Flows is locked off.
   Confirmed Oct 30, 2026 (`docs/guides/fsl-mobile-setup.md`).

## DO NOT

- **DO NOT** write org passwords, tokens or session IDs into files, docs or commits. Use the
  existing `sf` CLI auth.
- **DO NOT** commit `fsl: true` / `pest: true` / `agents: true` in `cumulusci.yml`. Repo
  defaults are false; flip them locally only for a flow or UX assembly run, then revert.
- **DO NOT** redeploy `post_pest_sla` once its entitlement process is active (in use). Use
  `deploy_post_pest_sla`, which skips when the process exists.
- **DO NOT** edit `unpackaged/post_ux/`. Change `templates/` and run `assemble_and_deploy_ux`.
- **DO NOT** delete activated orders or posted invoices to clean up; strip and archive accounts.

## Workflow

```
- [ ] 1. Identify the org
- [ ] 2. Inventory what it has
- [ ] 3. Deploy what's missing or changed
- [ ] 4. Post-deploy setup (permissions, activation, data)
- [ ] 5. Run the pest tests
- [ ] 6. Live check and re-inventory
```

**1. Identify the org**

```bash
cci org list                                   # CCI alias ↔ username
sf org display --target-org <username>         # instance, API version, edition
```

Check the org has Field Service and Revenue Cloud licences before going further. Pest
needs FSL (`prepare_fsl`) in place.

**2. Inventory**

```bash
python scripts/ai/pest_org_inventory.py --target-org <username>
```

It dry-runs each bundle (nothing is saved; about 3 minutes) and runs SOQL checks. Read it as:

| Mark | Meaning | Action |
|------|---------|--------|
| `+` Created | Component missing from the org | Deploy that bundle |
| Changed (count) | Differs, or a type that always reports Changed (OmniDataTransform, Flow, PermissionSet) | Deploy if you changed it in the repo |
| `!` failing | Would fail to deploy | Fix first; see [debugging.md](debugging.md) |
| `~` | Already there and locked (e.g. active agent version) | Nothing, unless you must change it |
| `✗` data check | Seed data or setup missing | Run the task it names |

Use `--bundles post_pest` to recheck one bundle, `--skip-dry-run` for data checks only.

**3. Deploy**

Existing org, a few changed components: deploy just those files (fast, no flow side effects).

```bash
cd unpackaged/post_pest
sf project deploy start --target-org <username> --wait 20 \
  --source-dir classes/RLM_RTK_FieldQuote.cls --source-dir lwc/rlmRtkInspectQuote
```

Whole bundle missing or stale: use its CCI task, which carries the right options.

| Bundle | Tasks, in order |
|--------|-----------------|
| post_fsl | `deploy_post_fsl` (or `prepare_fsl` on a new org) |
| post_pest_sla | `deploy_post_pest_sla` (skips if the process exists) |
| post_pest | `deploy_post_pest`, `assign_permission_sets -o api_names RLM_Rentokil_Pest` |
| post_pest_ai | `deploy_post_pest_ai`, `activate_pest_prompt_templates` |
| post_pest_docgen | `deploy_post_pest_docgen`, `activate_docgen_templates`, `fix_pest_document_template_binaries` |
| post_pest_agent | `deploy_agents_settings`, `deploy_post_pest_agent`, `assign_permission_sets -o api_names RLM_RTK_Pest_Billing_Agent`, `activate_pest_billing_agent` |

Order matters: `post_pest_sla` before `post_pest` (Apex references the process), `post_pest`
before docgen (Quote roll-ups and inspection objects).

New org: set `fsl: true` and `pest: true` locally, run `cci flow run prepare_fsl` then
`cci flow run prepare_pest --org <alias>`, then revert the flags.

UX (record pages, layouts): after editing `templates/flexipages/patches/pest/` or
`templates/layouts/pest/`, flip `fsl`/`pest` on locally and run
`cci task run assemble_and_deploy_ux --org <alias>`. Dry-run first with `-o deploy false`.

Docgen proposal mapping: edit `scripts/docgen/build_rtk_proposal_odts.py`, regenerate with
`python3 scripts/docgen/build_rtk_proposal_odts.py unpackaged/post_pest_docgen/omniDataTransforms`,
then deploy `omniDataTransforms`. Data mappings show `IsActive = false`; that's normal here.

**4. Post-deploy setup**

Run what the inventory's `✗` lines name. Common ones:
- New prices or zones: `refresh_dt_default_pricing`, then wait for the decision table refresh.
- Guarantees missing the response process: anonymous Apex `RLM_RTK_Coverage.syncAll();`.
- New fields: add field permissions to `RLM_Rentokil_Pest` in the same deploy.

**5. Run the pest tests**

```bash
sf apex run test --target-org <username> --wait 30 --result-format human \
  --class-names RLM_RTK_AITest --class-names RLM_RTK_BillExplainerTest \
  --class-names RLM_RTK_CoverageTest --class-names RLM_RTK_FieldAddOnTest \
  --class-names RLM_RTK_FieldQuoteTest --class-names RLM_RTK_FieldVisitTest \
  --class-names RLM_RTK_InspectionTest --class-names RLM_RTK_PlanChangeTest \
  --class-names RLM_FSL_ServiceBillingTest
```

Photo-upload tests can fail with `UNABLE_TO_LOCK_ROW` when run in parallel. Rerun those
classes alone before treating it as a failure.

**6. Live check**

Seed a visit with the `pest-demo-seed-visits` skill and open it, or exercise the changed Apex
with anonymous Apex inside `Database.setSavepoint()` / `Database.rollback()`. Then rerun the
inventory and confirm the gaps are gone.

## Additional resources

- Known deploy and runtime failures with fixes: [debugging.md](debugging.md)
- Org built from the Salesforce demo template (SDO / `RC_*` names, no `prepare_rlm_org`)?
  Read `docs/analysis/sdo-org-pest-overlay-findings.md` first: the context, billing
  policy, sequence policy and layout gaps all need handling before the story works.
  `cci task run patch_sdo_org_for_pest` adds the pest actions to the template's own
  layouts and record pages and makes its Work Order forms flow test-safe.
- A clean deploy doesn't mean the phone works. For mobile app login, the edit and status
  settings, and licensing, see `docs/guides/fsl-mobile-setup.md`; for actions that work on
  desktop but not in the app, see `.cursor/skills/fsl-mobile-lwc/SKILL.md`.
