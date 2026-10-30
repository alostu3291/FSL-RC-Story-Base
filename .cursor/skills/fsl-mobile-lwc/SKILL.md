---
name: fsl-mobile-lwc
description: How to build, wire and debug Lightning web components that run as quick actions in the Salesforce Field Service mobile app - placement on layouts, the mobile permission set, photos and files, closing and reloading, what the app doesn't support, and how to test on a device. Use when creating or changing an LWC, quick action or layout meant for technicians in the Field Service app, or when something works on desktop but not in the app.
---

# LWCs in the Field Service Mobile App

The app hosts LWCs in an embedded web view with its own session, and it builds record screens
from page layouts, not Lightning record pages. Most of what works on desktop needs a second
look there. Everything below was hit on a device while building the pest demo
(`unpackaged/post_pest/lwc`, `unpackaged/post_docgen/lwc`).

## Quick Rules

1. Expose the component as `lightning__RecordAction` with `actionType` `ScreenAction`, and wrap
   it in a `LightningWebComponent` quick action on Work Order or Service Appointment.
2. Put the action in the page layout's **Salesforce Mobile and Lightning Experience Actions**
   (`platformActionList`). Flexipage actions and components don't show in the app.
3. Technicians start from their appointment or work order. Put actions there, not on Account
   or Quote.
4. The user needs `RLM_FSL_Mobile_Extensions` (the `LightningOnFSMobile` permission) assigned
   directly, plus `FieldServiceMobileStandardPermSet`.
5. Load data from a `recordId` setter; quick actions can set it after `connectedCallback`.
6. Don't use `lightning-file-upload`, `filePreview` navigation or relative `/sfc/` file URLs.
7. Expect a connection. Custom LWCs and Apex calls don't work offline.
8. After a deploy, log out of the app and back in before judging a fix.

## DO NOT

- **DO NOT** rely on a desktop page component (Milestones, related list components, record
  detail) to reach technicians; build it into the action.
- **DO NOT** use the browser Speech Recognition API; it asks for permission and then does
  nothing in the app.
- **DO NOT** leave a mobile screen waiting on an event that may never arrive; give it a way out.
- **DO NOT** put `RLM_FSL_Mobile_Extensions` or `FieldServiceMobileStandardPermSet` in a
  permission set group; license-owned permission sets can't go in one.

## Wiring an action

```xml
<!-- lwc/myAction/myAction.js-meta.xml -->
<targets><target>lightning__RecordAction</target></targets>
<targetConfigs>
    <targetConfig targets="lightning__RecordAction">
        <actionType>ScreenAction</actionType>
    </targetConfig>
</targetConfigs>
```

```xml
<!-- quickActions/WorkOrder.My_Action.quickAction-meta.xml -->
<actionSubtype>ScreenAction</actionSubtype>
<label>My Action</label>
<lightningWebComponent>myAction</lightningWebComponent>
<type>LightningWebComponent</type>
```

Add `WorkOrder.My_Action` to the layout's `platformActionList` in `templates/layouts/pest/`
(the UX assembly deploys it; see `docs/features/dynamic-ux-assembly.md`). To also show it on
desktop, add it to the flexipage patch (`templates/flexipages/patches/pest/`). Both pest
actions are examples: `WorkOrder.RLM_RTK_Treatment` (`rlmRtkTreatmentAction`) and
`ServiceAppointment.RLM_RTK_Inspect_and_Quote` (`rlmRtkFieldVisit`).

One action per job works better than many small ones: `rlmRtkTreatmentAction` hosts the visit
brief, the response countdown, Start treatment, the checklist, Find & Add, Change the plan and
the visit summary on one screen.

## recordId and closing

Quick actions can set `recordId` after `connectedCallback`, so load from the setter:

```js
_recordId;
@api
get recordId() { return this._recordId; }
set recordId(value) {
    const changed = value !== this._recordId;
    this._recordId = value;
    if (changed && value) this.load();
}
```

Close with `this.dispatchEvent(new CloseActionScreenEvent())` from `lightning/actions`. After a
save, reload from Apex rather than trusting cached wire data.

## Photos and files

| Need | Works in the app | Doesn't |
|------|------------------|---------|
| Take or pick a photo | `<input type="file" accept="image/*">`, resize to JPEG on a canvas, send base64 to Apex (`rlmRtkPhotoCapture`) | `lightning-file-upload` |
| Show an image | `<img src>` with the absolute `ContentVersion.VersionDataUrl` from Apex | Relative `/sfc/servlet...` URLs (wrong origin, no session cookie) |
| Show a PDF | Page renditions fetched through Apex, gzip-decompressed in JS, shown as images (`rlmFileViewer`) | `filePreview` navigation, iframes, PDF links |

- Resize to 1600 px at 80% JPEG quality. Apex request payloads cap out around 4 MB of base64,
  so refuse originals over 3 MB that can't be decoded. Resizing also converts iPhone HEIC.
- Renditions are generated after upload, so retry the first page of a new PDF a few times.
- Files aren't in the app's offline data by default.

## Platform features the app doesn't give you

- **Milestones:** the standard countdown is a desktop page component; the app shows only the
  Milestone Status field. `rlmRtkResponseGuarantee` is the replacement.
- **Speech to text:** use the keyboard's mic and a "Fill from notes" button.
- **Edit pencil and status picker:** off unless the org's Field Service Mobile Settings record
  turns them on (`IsShowEditFullRecord`, `QuickStatusChangeFlowName`). The pest actions have
  their own Start and Complete buttons instead (`RLM_RTK_FieldVisit.startVisit`). When
  Apex sets an appointment status, go through `RLM_RTK_FieldVisit.stepToward` first. The
  managed FSL package rejects skipped lifecycle steps when the org has no transitions
  configured, and always in tests.
- **Long waits:** document generation never reported back on mobile. `rlmDocStatusMonitor`
  checks `FORM_FACTOR` and returns to the record after 2.5 seconds on phones and tablets.
- **Signatures:** a drawn canvas signature is not saved anywhere unless you save it. The
  native Service Report signature works offline and stores a `DigitalSignature`.

## Apex behind the action

- Return one state object per screen (`getState`, `getContext`) so the action makes few calls
  on a slow connection.
- Callouts, including Einstein prompt templates, must run before any DML in the transaction.
- `ConnectApi.EinsteinLLM` doesn't compile without Einstein, so `RLM_RTK_AI` finds the
  generator class by name at runtime and falls back to the rules.

## Testing on a device

1. Deploy, then log out of the app and back in. If the app can't sign in at all
   (`oauth_approval_error_generic`), turn on **Require PKCE** in Setup → OAuth and OpenID
   Connect Settings (see `docs/guides/fsl-mobile-setup.md`).
2. Seed a visit dispatched to your user (`pest-demo-seed-visits` skill). The app only lists
   appointments assigned to you, Scheduled or Dispatched, with a start time.
3. Open the appointment or work order, then the action.
4. If it fails only in the app, there are no developer tools there. Open the same action in a
   desktop browser at phone width, or use Android remote debugging, and compare.

## Additional resources

- Mobile app setup, login and licensing: `docs/guides/fsl-mobile-setup.md`
- Pest components and actions: `docs/guides/pest-control-demo.md`
