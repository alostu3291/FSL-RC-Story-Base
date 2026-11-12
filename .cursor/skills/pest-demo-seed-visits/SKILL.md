---
name: pest-demo-seed-visits
description: Seeds Verdant pest demo data - the whole demo cast (one customer per scene, with billing history, plan changes and the demo day's visits) or single fresh visits for the two field flows (a new prospect's inspection, a Covered re-service) - and verifies each seed. Use when asked to seed, reset or prepare demo data, customers or visits for the pest or Field Service demo.
---

# Pest Demo Seed Visits

## Whole cast (all nine scenes)

`cci task run seed_rtk_demo_cast --org <cci_alias>` seeds Nora Castillo (prospect, scenes 1-3),
Aisha Brooks (ordered, first treatment booked, 4-5), Casey Morgan (Covered rodent re-service, 7-8),
Sam Patel ($366 first bill, winter mosquito pause, Not Covered re-service, 6-9) and Dana Whitfield
($20 prorated upgrade bill, 8). The cast is defined in `tasks/rlm_rtk_seed_cast.py` (`build_cast`);
the table is in `docs/guides/pest-control-demo.md` (Demo cast). It takes about three minutes the first
time and is idempotent. `-o customers "Aisha Brooks,Sam Patel"` seeds a subset, `-o days_ahead 2`
moves the demo day. A cast member whose scene was run live is used up: rename the account
"zz Archived - ..." and re-run. Report its output with the template below.

## Single visits

Two CCI tasks book visits dispatched to the running user, in the Bloomingdale IL territory,
at an hour on the territory's clock (America/Chicago). Both are idempotent: re-running moves
the open visit to the new time instead of booking another.

| Flow | Task | Customer |
|------|------|----------|
| New customer: Inspect & Quote → Sign & Pay → treatment | `seed_rtk_prospect_inspection` | New prospect (no plans) |
| Covered re-service → Treatment → Change the plan | `seed_rtk_reservice` | Existing customer whose guarantee covers the pest |

## Quick Rules

1. Check what's already booked and used before seeding (step 1). Flows that were run are
   used up: an inspected prospect has plans, a completed re-service is closed.
2. A new prospect needs a new name and its own street (duplicate rules match on address).
3. A re-service is only Covered when an active guarantee covers the reported pest.
4. Avoid the same hour as another visit for the running user tomorrow.
5. A plan change takes effect the next day, so a customer who ran Change the plan today is
   on the new tier tomorrow. A customer moved to Home Protection Plus has no upgrade left to
   demo; seed a Home Protection customer instead.
6. Report back the work order and appointment numbers, times in Central, and what the
   user will see.

## DO NOT

- **DO NOT** reuse a prospect who already has plans; the task refuses it. Pick a new name.
- **DO NOT** delete used customers. Archive with the "zz Archived - …" rename if asked.
- **DO NOT** write org credentials into scripts or docs.

## Workflow

**1. See what's booked and what's used**

```bash
sf data query --target-org <username> -q "SELECT Account.Name, WorkOrderNumber, WorkType.Name, Status, (SELECT AppointmentNumber, Status, SchedStartTime FROM ServiceAppointments) FROM WorkOrder WHERE CreatedDate = LAST_N_DAYS:3 AND WorkType.Name IN ('Pest Inspection','Pest Re-service') ORDER BY CreatedDate"
```

Unused means the work order is New and the appointment is Dispatched. Note the hours already
taken tomorrow.

**2. Pick a re-service customer**

```bash
sf data query --target-org <username> -q "SELECT Account.Name, Name, RLM_RTK_Covered_Pests__c FROM Entitlement WHERE RLM_RTK_Covered_Pests__c != null AND StartDate <= TODAY AND (EndDate = null OR EndDate >= TODAY) AND (NOT Account.Name LIKE 'zz%') ORDER BY Account.Name"
```

Prefer a Home Protection customer without Termite: Change the plan then shows an upgrade
(Plus), a downgrade (Essential) and an add-on (Termite), each with the size and severity
adjustment. Skip customers with an open re-service or a scheduled `Plan change:` order.

**3. Seed**

```bash
cci task run seed_rtk_prospect_inspection --org <cci_alias> \
  -o account_name "Elena Ruiz" -o street "29 Hawthorn Ln" -o phone "(630) 555-0207" -o hour 15

cci task run seed_rtk_reservice --org <cci_alias> \
  -o account_name "Casey Morgan" -o pest Rodents -o hour 8 \
  -o description "Customer hears scratching in the attic again and found fresh droppings by the furnace."
```

Options: `hour` (0-23, Central), `days_ahead` (default 1), `subject`, `description`.
`pest` values: Ants, Spiders, Cockroaches, Rodents, Termites, Mosquitoes, Wasps / Bees,
Bed Bugs, Other. No plan covers Bed Bugs.
`-o require_coverage false` books a Not Covered re-service (billed, no countdown).

The task logs what it booked. For a re-service, expect `Covered by: <guarantee>` and
`Re-service Response due <time>`. If it says Covered but there's no milestone, see the
`pest-demo-org-deploy` skill (`RLM_RTK_Coverage.syncAll();`).

**4. Verify what the user will see**

Optional but worth it before a demo. Plan-change prices for the re-service customer:

```apex
RLM_RTK_PlanChange.State s = RLM_RTK_PlanChange.getState('<re-service work order Id>');
System.debug(s.adjustment + ' ' + s.adjustmentReasons);
for (RLM_RTK_PlanChange.Plan t : s.tiers) System.debug(t.name + ' ' + t.price + ' = ' + t.listPrice + ' + ' + t.adjustment);
```

Pre-generate the visit briefs so the screens open quickly:
`RLM_RTK_AI.getBrief('<work order Id>', false);` for each work order.

## Report template

```markdown
**Flow 1: <prospect>**, new prospect at <street>. Free Pest Inspection: work order <n>,
appointment <SA>, <day> at <time> Central.

**Flow 2: <customer>**, <pest> re-service: work order <n>, appointment <SA>, <time> Central.
Covered by <guarantee>; response milestone due <day time> Central. Change the plan shows
<current tier price = list + adjustment>, <upgrade>, <downgrade>, <add-ons>.
```

## Additional resources

- Scripts: `scripts/apex/seedRtkProspectInspection.apex`, `scripts/apex/seedRtkReservice.apex`;
  cast stages `seedRtkCastQuote.apex`, `seedRtkCastOrder.apex`, `seedRtkCastTreatment.apex`, `seedRtkCastPlanChange.apex`
- Task classes: `tasks/rlm_rtk_seed_visit.py` (fills `%%%OPTION%%%` tokens, reports results),
  `tasks/rlm_rtk_seed_cast.py` (runs the cast stages and waits for each asynchronous step)
- Flow walkthrough: `docs/guides/pest-control-demo.md`
