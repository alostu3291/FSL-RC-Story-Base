# Field Service Mobile App: Setup, Login and Licensing

What a user needs before the Salesforce Field Service mobile app can run this repo's
technician actions, and the problems we hit getting there. For building the actions
themselves, see `.cursor/skills/fsl-mobile-lwc/SKILL.md`.

## What the build sets up

With `fsl: true`, `prepare_fsl` gives the running user (who plays seller, dispatcher and
technician in the demo) everything Salesforce's setup checklist asks for:

| Need | Where |
|------|-------|
| Field Service permission set licenses | `rlm_fsl_psl_api_names` in `cumulusci.yml`: `FieldServiceStandardPsl`, `FieldServiceDispatcherPsl`, `FieldServiceSchedulingPsl`, `FieldServiceMobilePsl` |
| Field Service permissions | `RLM_Field_Service_PSG` (`psg_fsl`) |
| Mobile app access and LWC actions in the app | `FieldServiceMobileStandardPermSet` and `RLM_FSL_Mobile_Extensions` (`ps_fsl`), assigned directly because license-owned permission sets can't go in a group |
| Territory, operating hours, work types, the user as a service resource | `prepare_fsl` data and Apex steps |
| Technician actions on Work Order and Service Appointment layouts | `templates/layouts/fsl/`, `templates/layouts/pest/` |

`RLM_FSL_Mobile_Extensions` grants `LightningOnFSMobile` (Lightning SDK for Field Service
Mobile). Without it, LWC quick actions don't appear in the app.

## Logging in

1. In the app, choose **Use Custom Domain** and enter the org's My Domain prefix (the part
   before `.my.salesforce.com`).
2. Sign in as the demo user.
3. If you get an OAuth error after a first attempt, go to **Setup → Connected Apps OAuth Usage**
   and click **Install** on the Field Service app.

### "oauth_approval_error_generic" and the user-agent flow

The Field Service iOS app (version 264.1.1, Oct 2026) still signs in with the OAuth
user-agent flow, which Salesforce is retiring.

- Orgs created from Winter '27 on have **Allow OAuth User-Agent Flows** (Setup → OAuth and
  OpenID Connect Settings) locked off. The app can't sign in to them, and nothing in the org
  fixes it. This is why `fsl-rc` can't use the app.
- In older orgs the toggle can still be turned on, until Salesforce's enforcement date
  (announced as Feb 20, 2027).
- **Login History** shows the cause: an entry for the Field Service app with
  "User-Agent Flow Disabled". If there's no entry at all, the attempt went to another org
  or domain.

Workarounds: use an older org with the toggle on (the demo uses
`rc-apr8-customer-template`), run the technician screens in a phone browser, or open a
Salesforce support case about the iOS app.

## What shows up in the app

- **Schedule:** only appointments whose parent is a work order, where the user is the assigned
  resource, with status Scheduled or Dispatched and a scheduled start. That's why a pest
  inspection is a lightweight Pest Inspection work order. The seed tasks in
  `.cursor/skills/pest-demo-seed-visits/SKILL.md` book visits that way.
- **Record screens:** built from page layouts and compact layouts, not Lightning record pages.
  Related lists on the layout show if the app supports the object.
- **Actions:** the layout's Salesforce Mobile and Lightning Experience Actions.
- **Edit pencil:** only when the org's Field Service Mobile Settings record has **Show Edit
  Full Record** (`IsShowEditFullRecord`) on and Edit is in the layout's actions.
- **Status picker on an appointment:** only when the settings record names a Field Service
  Mobile flow in **Quick Status Change Flow** (`QuickStatusChangeFlowName`). Otherwise use an
  Update a Record action or an app extension flow. The pest actions have their own Start and
  Complete buttons.
- **Milestones:** only the Work Order's Milestone Status field. The standard countdown is
  desktop-only; the pest Treatment action shows its own (`rlmRtkResponseGuarantee`). Whether
  the Milestones related list renders on mobile hasn't been checked on a device.

Check the settings record with:

```bash
sf data query --target-org <username> -q "SELECT DeveloperName, IsDefault, IsShowEditFullRecord, QuickStatusChangeFlowName FROM FieldServiceMobileSettings"
```

## Licensing

Each user has one **user license** plus any number of **permission set licenses** for add-on
features. A permission set license only makes permission sets assignable; the user still
needs the permission sets or groups.

- **Field Service and Revenue Cloud on one user:** works on a full Salesforce user license. The
  demo user has both, so a technician can quote, amend and bill from the app (Inspect & Quote,
  Change the plan).
- **Technician-only seats:** Salesforce also sells cheaper licenses for people who only work
  jobs in the app. We haven't confirmed whether they can hold Revenue Cloud permission set
  licenses. To test, create a user on that license and assign
  `RevenueLifecycleManagementUserPsl` and `ProductDiscoveryUserPsl`. Salesforce rejects a
  permission set license that doesn't fit the user license, so the assignment is the test.
  Then run Inspect & Quote as that user in the app.

## Field Service Core vs the managed package

The demo runs on Field Service Core: work orders, appointments, assets, maintenance plans,
entitlements and milestones, territories, and the mobile app. The managed package (`FSL`
namespace, AppExchange) adds the Dispatcher Console, automatic booking and scheduling rules,
route optimization, appointment booking windows and Appointment Assistant arrival texts. The
mobile app doesn't need the package. The demo deck marks the scenes that change with it.

## Offline

Custom LWC actions and their Apex calls need a connection. Screen flows can run offline only
with supported components and data downloaded in advance (briefcase priming). Files aren't
downloaded for offline use by default. Plan the demo where there's signal.
