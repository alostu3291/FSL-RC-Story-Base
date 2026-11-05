---
name: hvac-demo-seed-visits
description: Seeds fresh Brightline Home Comfort (HVAC) demo data for the three stories - a new homeowner's System Check (Check & Quote, Sign & Pay, Initial Tune-up), a system replacement quote (Replacement Options, Replacement Install), and a covered No-Cool / No-Heat call for an existing agreement customer (priority response countdown, Find & Add member pricing) - and verifies each seed. Also resets the Brightline Commercial (Lakeshore Property Group) stories - refrigerant leak history with a dispatched data room visit, a covered emergency call at a restaurant site, and the capital project. Use when asked to seed, reset or prepare demo data, customers or visits for the HVAC or Brightline demo.
---

# HVAC Demo Seed Visits

Three CCI tasks, all dispatched to the running user in the Naperville IL territory, with hours
on the territory's clock (America/Chicago). All are safe to re-run.

| Story | Task | Customer |
|-------|------|----------|
| New customer: Check & Quote → Sign & Pay → Initial Tune-up | `seed_hvac_prospect_check` | New prospect (no agreement) |
| Replacement: Check & Quote → Replacement Options → Sign & Pay → Replacement Install | `seed_hvac_prospect_check` | New prospect; the tech records old or failing equipment |
| Existing customer: covered No-Cool call → Service Checklist → Find & Add | `seed_hvac_agreement_customer`, then `seed_hvac_service_call` | Customer with an active comfort agreement |

`seed_hvac_agreement_customer` makes an existing customer by running the real sale through the
same Apex the app calls: system check with findings, quote, proposal PDF, Sign & Pay, activated
order, and the Initial Tune-up booked and completed with its checklist and a fixed capacitor.
The customer ends up with real entitlements, a maintenance plan and a posted invoice. It takes
2-4 minutes, mostly waiting on fulfillment and billing, and resumes where it stopped if re-run.

## Quick Rules

1. Check what's booked and used first (step 1). A prospect who signed is used up for the
   new-customer and replacement stories; a completed service call is closed.
2. Every new customer needs a new name and its own street (duplicate rules match on address).
3. A service call is only Covered when an active agreement covers the issue: Comfort plans
   cover No Cool, No Heat, Noise, Water Leak and Thermostat; Indoor Air Quality covers Air
   Quality; water heater coverage covers Water Heater.
4. Avoid an hour already taken tomorrow by the running user. Tune-up and check slots are
   8, 10, 13 and 15.
5. Response targets by tier: Premier 4 hours, Plus 8, Basic 24 (service hours). Pick the tier
   that gives the countdown you want to show.
6. Report back the work order and appointment numbers, times in Central, and what the user
   will see.

## DO NOT

- **DO NOT** reuse a prospect who already has an agreement for a System Check; the task refuses it.
- **DO NOT** delete used customers. Archive with a "zz Archived - …" rename if asked.
- **DO NOT** seed Verdant pest data (`seed_rtk_*`) for the HVAC demo; that's the other story.
- **DO NOT** write org credentials into scripts or docs.

## Workflow

**1. See what's booked and who's used**

```bash
sf data query --target-org <username> -q "SELECT Account.Name, WorkOrderNumber, WorkType.Name, Status, (SELECT AppointmentNumber, Status, SchedStartTime FROM ServiceAppointments) FROM WorkOrder WHERE CreatedDate = LAST_N_DAYS:3 AND WorkType.Name IN ('System Check','No-Cool / No-Heat Call','Replacement Install') ORDER BY CreatedDate"
sf data query --target-org <username> -q "SELECT Account.Name, Name, RLM_HVAC_Covered_Systems__c FROM Entitlement WHERE RLM_HVAC_Covered_Systems__c != null AND StartDate <= TODAY AND (EndDate = null OR EndDate >= TODAY) AND (NOT Account.Name LIKE 'zz%') ORDER BY Account.Name"
```

Unused means the work order is New and the appointment is Dispatched. The second query lists
agreement customers; skip any with an open No-Cool call.

**2. Seed**

New customer, and a replacement prospect (the description sets up the story; the tech records
the old equipment and its problems in Check & Quote):

```bash
cci task run seed_hvac_prospect_check --org <cci_alias> \
  -o account_name "Elena Ruiz" -o street "29 Hawthorn Ln" -o phone "(630) 555-0207" -o hour 10

cci task run seed_hvac_prospect_check --org <cci_alias> \
  -o account_name "Walt Kaminski" -o street "412 Jefferson Ave" -o hour 13 \
  -o description "Furnace is from 2008 and the AC barely keeps up; homeowner smelled something odd at startup."
```

For the replacement, in Check & Quote enter an install year 12 or more years back (or a Safety
finding such as a cracked heat exchanger); Replacement Options then suggests a system.
The systems are Good / Better / Best Heat Pump System ($8,900 / $11,500 / $14,800 before zone).

Existing customer with a covered call:

```bash
cci task run seed_hvac_agreement_customer --org <cci_alias> \
  -o account_name "Dana Whitfield" -o street "77 Brookdale Dr" -o phone "(630) 555-0144" \
  -o plan Plus -o iaq true

cci task run seed_hvac_service_call --org <cci_alias> \
  -o account_name "Dana Whitfield" -o issue "No Cool" -o hour 8
```

`seed_hvac_agreement_customer` options: `plan` Basic / Plus / Premier (default Plus),
`system_type` AcFurnace / HeatPump, `systems` 1-4, `install_year` (default 2015), `iaq`,
`water_heater`, `repair` (default true: a weak capacitor found and replaced on the tune-up).
If it times out, re-run the same command; it continues from the last finished step.

`seed_hvac_service_call` options: `issue` No Cool, No Heat, Noise, Water Leak, Thermostat,
Air Quality or Water Heater; `hour`, `days_ahead` (default 1), `subject`, `description`.
`-o require_coverage false` books a Not Covered call (diagnostic fee, no countdown).

The task logs what it booked. For a service call expect `Covered by: <agreement>`,
`Priority: <High/…>` and `Priority Response due <time>`. Covered with no milestone means the
SLA bundle is missing (`deploy_post_hvac_sla`).

**3. Verify what the user will see**

Optional but worth it before a demo. Pre-generate the visit briefs so screens open quickly:
`RLM_HVAC_AI.getBrief('<work order Id>', false);` for each seeded work order.

Member prices on the service call (Basic 10%, Plus 15%, Premier 100% off repairs):

```apex
RLM_HVAC_FieldAddOn.State s = RLM_HVAC_FieldAddOn.getState('<service call work order Id>');
System.debug(JSON.serialize(s));
```

## Report template

```markdown
**New customer: <prospect>**, <street>. Free System Check: work order <n>, appointment <SA>,
<day> at <time> Central.

**Replacement: <prospect>**, <street>. System Check: work order <n>, appointment <SA>,
<day> at <time> Central. In Check & Quote, record <equipment, year, finding>.

**Existing customer: <customer>**, <tier> agreement (<covered systems>), maintenance plan <MP>.
<Issue> call: work order <n>, appointment <SA>, <time> Central. Covered by <agreement>,
<priority> priority, response due <day time> Central.
```

## Commercial (Lakeshore Property Group)

The commercial stories reset in place on one fixture rather than seeding new customers. The
Lakeshore contract must be booked first, because the leak visit and the covered call need it.

```bash
cci flow run reset_hvac_commercial_demo --org <cci_alias>    # all four steps below
cci task run seed_hvac_refrigerant_leak --org <cci_alias>    # -o account_name, -o hour, -o days_ahead
cci task run seed_hvac_commercial_service_call --org <cci_alias> -o account_name "Ember & Oak Bistro"
cci task run reset_hvac_capital_project --org <cci_alias>
```

The flow's steps are gated on `hvac` and `hvac_commercial`.

- **Refrigerant leak:** cancels open leak repairs at the site, deletes its refrigerant logs and
  seeds a year of history, then dispatches the site's next quarterly maintenance visit to the
  running user, tomorrow at 9 Central. The first tracked unit by tag is the one near the limit;
  at the Data Room that's RTU-03 (62 lb) at 7.9%. On that visit, Refrigerant Log with 2.5 lb or
  more on RTU-03 crosses 10%. The unit turns Leak Repair Due with a 30-day deadline, and a
  Commercial Leak Repair work order opens. Re-running the task undoes it.
- **Emergency call:** defaults to Harvest Table Restaurant, No Cool, at the next hour (`-o hour
  next`). Restaurants and the data room get Critical priority and a 4-hour countdown; offices
  get next business day. It first moves the group's not-yet-started site response entitlements
  to start today (contracts start on the first of next month).
- **Capital project:** rejects unbooked project quotes, cancels open project step work orders
  and restores replaced units. Booked project orders and their invoices stay.
- **Add a site:** `seed_hvac_commercial_new_site` (Westfield Commons Office) can only be shown
  once per contract; it isn't reset.

Report: the maintenance visit's work order and appointment, the watch unit and the pounds that
trip the limit; the call's work order, priority and response due time in Central.

## Additional resources

- Scripts: `scripts/apex/seedHvacProspectCheck.apex`, `scripts/apex/seedHvacNoCoolCall.apex`,
  `scripts/apex/seedHvacRefrigerantLeak.apex`, `scripts/apex/coverHvacCommercialFromToday.apex`,
  `scripts/apex/resetHvacCapitalProject.apex`
- Task classes: `tasks/rlm_hvac_seed_visit.py` (prospect check and service call),
  `tasks/rlm_hvac_seed_agreement.py` (agreement customer)
- Build plan and story: `docs/analysis/hvac-demo-build-plan.md`
