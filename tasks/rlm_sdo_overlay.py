"""Fit the pest demo onto an org built from the Salesforce demo template (SDO).

Template orgs assign their own page layouts and Lightning record pages, so the repo's pest
layouts never show. This task patches whatever the org actually uses, in place:

  layouts   — adds the pest quick actions (``*.RLM_RTK_*`` in templates/layouts/pest) and
              any missing pest ``RLM_*`` fields to the layouts assigned to the given profiles.
  pages     — adds Work Order / Service Appointment lists to the app's Account record page
              and Maintenance Plan / Entitlement lists to its Asset record page.
  flows     — gives every Create Records element in the given flows a fault path, so a
              template flow that can't run in Apex tests (SDO SFS Attach Forms On Create)
              no longer blocks Work Order inserts.

Each step skips cleanly when the org doesn't have its target. Runs are idempotent.
Use ``deploy: false`` to retrieve and patch into ``work_dir`` without deploying.
"""

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    from cumulusci.tasks.salesforce import BaseSalesforceApiTask
    from cumulusci.core.exceptions import CommandException, TaskOptionsError
    from cumulusci.core.utils import process_bool_arg, process_list_arg
except ImportError:
    BaseSalesforceApiTask = object
    CommandException = Exception
    TaskOptionsError = Exception

    def process_bool_arg(value):
        return str(value).lower() in ("true", "1", "yes")

    def process_list_arg(value):
        if value is None or isinstance(value, list):
            return value
        return [v.strip() for v in str(value).split(",") if v.strip()]


PEST_LAYOUT_TEMPLATES = {
    "WorkOrder": "pest/WorkOrder-Work Order Layout.layout-meta.xml",
    "ServiceAppointment": "pest/ServiceAppointment-Service Appointment Layout.layout-meta.xml",
    "Quote": "pest/Quote-RLM Quote Layout.layout-meta.xml",
    "Account": "pest/Account-Account Layout.layout-meta.xml",
}

# Related lists copied (with their columns) from a repo layout template into the org's layouts.
LAYOUT_RELATED_LISTS = {
    "Account": ("pest/Account-Account Layout.layout-meta.xml", ["WorkOrders", "ServiceAppointmentAccount"]),
    "Asset": ("fsl/Asset-RLM Asset Layout.layout-meta.xml", ["MaintenanceAssets", "RelatedEntitlementList"]),
}
LAYOUT_OBJECTS = list(dict.fromkeys([*PEST_LAYOUT_TEMPLATES, *LAYOUT_RELATED_LISTS]))

# Layout elements that follow relatedLists, in Metadata API order.
LAYOUT_AFTER_RELATED_LISTS = [
    "relatedObjects", "runAssignmentRulesDefault", "showEmailCheckbox", "showHighlightsPanel",
    "showInteractionLogPanel", "showKnowledgeComponent", "showRunAssignmentRulesCheckbox",
    "showSolutionSection", "showSubmitAndAttachButton", "summaryLayout",
]
PEST_ACTION_MARKER = ".RLM_RTK_"
PEST_SECTION_LABEL = "Rentokil Pest"

# Column names are validated per related list at deploy time and differ between lists
# (WorkOrders wants Name, Entitlements wants the legacy ENTITLEMENT.* aliases).
RELATED_LISTS = {
    "Account": [
        {
            "api": "WorkOrders",
            "label": "Work Orders",
            "fields": ["Name", "Subject", "Status", "StartDate", "EndDate"],
            "sort": ("CreatedDate", "Descending"),
        },
        {
            # Matches on AccountId; ServiceAppointments matches ParentRecordId, which is
            # the Work Order for pest visits.
            "api": "ServiceAppointmentAccount",
            "label": "Service Appointments",
            "fields": ["Name", "Subject", "Status", "SchedStartTime", "SchedEndTime"],
            "sort": ("SchedStartTime", "Descending"),
        },
    ],
    "Asset": [
        {
            "api": "MaintenanceAssets",
            "label": "Maintenance Plans",
            "fields": ["Name", "MaintenancePlan", "NextSuggestedMaintenanceDate"],
            "sort": ("__DEFAULT__", "Default"),
        },
        {
            "api": "Entitlements",
            "label": "Entitlements",
            "fields": [
                "ENTITLEMENT.NAME",
                "ENTITLEMENT.TYPE",
                "ENTITLEMENT.STARTDATE",
                "ENTITLEMENT.ENDDATE",
                "ENTITLEMENT.STATUS",
            ],
            "sort": ("__DEFAULT__", "Default"),
        },
    ],
}

FAULT_ASSIGNMENT = "RLM_Continue_After_Fault"
FAULT_VARIABLE = "RLM_FaultCount"

# Top-level Flow elements in Metadata API order, used to place new elements.
FLOW_ELEMENT_ORDER = [
    "actionCalls", "apexPluginCalls", "apiVersion", "areMetricsLoggedToDataCloud",
    "assignments", "choices", "collectionProcessors", "constants", "customErrors",
    "customProperties", "decisions", "description", "dynamicChoiceSets", "environments",
    "exitRules", "formulas", "interviewLabel", "isAdditionalPermissionRequiredToRun",
    "isOverridable", "isTemplate", "label", "loops", "migratedFromWorkflowRuleName",
    "orchestratedStages", "overriddenFlow", "processMetadataValues", "processType",
    "recordCreates", "recordDeletes", "recordLookups", "recordRollbacks", "recordUpdates",
    "runInMode", "screens", "sourceTemplate", "stages", "start", "startElementReference",
    "status", "steps", "subflows", "textTemplates", "timeZoneSidKey", "transforms",
    "triggerOrder", "variables", "waits",
]


class PatchSdoOrgForPest(BaseSalesforceApiTask):
    """Patch a demo-template org's own layouts, record pages and flows for the pest demo."""

    task_options = {
        "steps": {
            "description": "Comma list of steps to run: layouts, pages, flows. Default: all.",
            "required": False,
        },
        "profiles": {
            "description": "Profiles whose assigned layouts get the pest actions. "
            "Default: System Administrator.",
            "required": False,
        },
        "app": {
            "description": "Lightning app whose Account / Asset record pages get the related "
            "lists. Default: RC_Revenue_Cloud.",
            "required": False,
        },
        "fault_tolerant_flows": {
            "description": "Flows whose Create Records elements get fault paths. "
            "Default: SDO_SFS_Attach_Forms_On_Create.",
            "required": False,
        },
        "deploy": {
            "description": "Deploy the patched metadata. Default: true. "
            "false retrieves and patches into work_dir only.",
            "required": False,
        },
        "work_dir": {
            "description": "Where to keep the retrieved and patched files. "
            "Default: a temp dir, removed after a deploy.",
            "required": False,
        },
    }

    def _init_options(self, kwargs):
        super()._init_options(kwargs)
        self.steps = process_list_arg(self.options.get("steps")) or ["layouts", "pages", "flows"]
        unknown = set(self.steps) - {"layouts", "pages", "flows"}
        if unknown:
            raise TaskOptionsError(f"Unknown steps: {', '.join(sorted(unknown))}")
        self.profiles = process_list_arg(self.options.get("profiles")) or ["System Administrator"]
        self.app = self.options.get("app") or "RC_Revenue_Cloud"
        self.flows = process_list_arg(self.options.get("fault_tolerant_flows")) or [
            "SDO_SFS_Attach_Forms_On_Create"
        ]
        self.deploy = process_bool_arg(self.options.get("deploy", True))

    def _run_task(self):
        repo_root = Path(self.project_config.repo_root)
        self.templates_dir = repo_root / "templates" / "layouts"
        self._field_cache: Dict[str, set] = {}
        self._patched_flows: List[str] = []
        keep = bool(self.options.get("work_dir"))
        work = Path(self.options.get("work_dir") or tempfile.mkdtemp(prefix="sdo_pest_"))
        self._init_project(work)

        changed: List[Path] = []
        if "layouts" in self.steps:
            changed += self._patch_layouts(work)
        if "pages" in self.steps:
            changed += self._patch_pages(work)
        if "flows" in self.steps:
            changed += self._patch_flows(work)

        if not changed:
            self.logger.info("Nothing to patch; the org already has the pest additions.")
        elif not self.deploy:
            self.logger.info(f"deploy=false: {len(changed)} patched file(s) left in {work}")
        else:
            self._deploy(work, changed)
            self._activate_latest_flow_versions()

        if not keep and self.deploy:
            shutil.rmtree(work, ignore_errors=True)

    # ------------------------------------------------------------------ layouts

    def _patch_layouts(self, work: Path) -> List[Path]:
        assigned = self._assigned_layouts()
        if not assigned:
            self.logger.warning(f"No layouts assigned to {', '.join(self.profiles)}; skipping layouts.")
            return []
        self._retrieve(work, [f"Layout:{name}" for name in assigned])

        changed = []
        for full_name, sobject in assigned.items():
            path = work / "force-app" / "main" / "default" / "layouts" / f"{full_name}.layout-meta.xml"
            if not path.exists():
                self.logger.warning(f"  {full_name}: not retrieved; skipping")
                continue
            text = path.read_text(encoding="utf-8")
            added_actions, added_fields, added_lists = [], [], []
            if sobject in PEST_LAYOUT_TEMPLATES:
                template = self._template(PEST_LAYOUT_TEMPLATES[sobject])
                actions = [a for a in _layout_actions(template) if PEST_ACTION_MARKER in a[0]]
                text, added_actions = _add_layout_actions(text, actions)
                fields = [f for f in _layout_fields(template) if f.startswith("RLM_")]
                fields = [f for f in fields if f in self._object_fields(sobject)]
                text, added_fields = _add_layout_section(text, fields, PEST_SECTION_LABEL)
                if added_actions is None:
                    self.logger.warning(
                        f"  {full_name}: no Record platformActionList; add the pest actions in the layout editor"
                    )
                    added_actions = []
            if sobject in LAYOUT_RELATED_LISTS:
                source, names = LAYOUT_RELATED_LISTS[sobject]
                text, added_lists = _add_layout_related_lists(text, self._template(source), names)
            if added_actions or added_fields or added_lists:
                path.write_text(text, encoding="utf-8")
                changed.append(path)
                self.logger.info(
                    f"  {full_name}: +actions {added_actions or '-'}, +fields {added_fields or '-'}, "
                    f"+related lists {added_lists or '-'}"
                )
            else:
                self.logger.info(f"  {full_name}: already patched")
        return changed

    def _assigned_layouts(self) -> Dict[str, str]:
        """Full layout name → object, for the pest objects and the configured profiles."""
        profiles = ", ".join(_soql_quote(p) for p in self.profiles)
        objects = ", ".join(_soql_quote(o) for o in LAYOUT_OBJECTS)
        soql = (
            "SELECT Layout.Name, Layout.NamespacePrefix, TableEnumOrId FROM ProfileLayout "
            f"WHERE Profile.Name IN ({profiles}) AND TableEnumOrId IN ({objects})"
        )
        assigned = {}
        for r in self.tooling.query_all(soql).get("records", []):
            layout = r.get("Layout") or {}
            name = layout.get("Name")
            if not name:
                continue
            ns = layout.get("NamespacePrefix")
            full = f"{r['TableEnumOrId']}-{ns + '__' if ns else ''}{name}"
            assigned[full] = r["TableEnumOrId"]
        return assigned

    def _template(self, relative: str) -> str:
        return (self.templates_dir / relative).read_text(encoding="utf-8")

    def _object_fields(self, sobject: str) -> set:
        if sobject not in self._field_cache:
            describe = getattr(self.sf, sobject).describe()
            self._field_cache[sobject] = {f["name"] for f in describe["fields"]}
        return self._field_cache[sobject]

    # -------------------------------------------------------------------- pages

    def _patch_pages(self, work: Path) -> List[Path]:
        found = self.tooling.query(
            f"SELECT Id FROM CustomApplication WHERE DeveloperName = {_soql_quote(self.app)}"
        ).get("records", [])
        if not found:
            self.logger.warning(f"App {self.app} not found; skipping record pages.")
            return []
        self._retrieve(work, [f"CustomApplication:{self.app}"])
        app_path = work / "force-app" / "main" / "default" / "applications" / f"{self.app}.app-meta.xml"
        if not app_path.exists():
            self.logger.warning(f"App {self.app} not retrieved; skipping record pages.")
            return []
        pages = _app_record_pages(app_path.read_text(encoding="utf-8"), list(RELATED_LISTS))
        if not pages:
            self.logger.warning(f"{self.app} assigns no Account / Asset record page; skipping.")
            return []
        self._retrieve(work, [f"FlexiPage:{page}" for page in pages.values()])

        changed = []
        for sobject, page in pages.items():
            path = work / "force-app" / "main" / "default" / "flexipages" / f"{page}.flexipage-meta.xml"
            if not path.exists():
                self.logger.warning(f"  {page}: not retrieved; skipping")
                continue
            text, added = _add_related_lists(
                path.read_text(encoding="utf-8"), sobject, RELATED_LISTS[sobject]
            )
            if added is None:
                self.logger.warning(f"  {page}: no Related tab; add the lists in Lightning App Builder")
            elif added:
                path.write_text(text, encoding="utf-8")
                changed.append(path)
                self.logger.info(f"  {page}: +related lists {added}")
            else:
                self.logger.info(f"  {page}: already has the related lists")
        return changed

    # -------------------------------------------------------------------- flows

    def _patch_flows(self, work: Path) -> List[Path]:
        names = ", ".join(_soql_quote(f) for f in self.flows)
        present = {
            r["ApiName"]
            for r in self.sf.query(
                f"SELECT ApiName FROM FlowDefinitionView WHERE ApiName IN ({names}) AND IsActive = true"
            ).get("records", [])
        }
        for missing in sorted(set(self.flows) - present):
            self.logger.info(f"  Flow {missing}: not active in this org; skipping")
        if not present:
            return []
        self._retrieve(work, [f"Flow:{name}" for name in sorted(present)])

        changed = []
        for name in sorted(present):
            path = work / "force-app" / "main" / "default" / "flows" / f"{name}.flow-meta.xml"
            if not path.exists():
                continue
            text, count = _add_fault_paths(path.read_text(encoding="utf-8"))
            if count:
                path.write_text(text, encoding="utf-8")
                changed.append(path)
                self.logger.info(f"  Flow {name}: fault paths on {count} Create Records element(s)")
            else:
                self.logger.info(f"  Flow {name}: already fault tolerant")
        self._patched_flows = [p.name.split(".")[0] for p in changed]
        return changed

    def _activate_latest_flow_versions(self):
        for name in self._patched_flows:
            rows = self.tooling.query(
                "SELECT Id, ActiveVersion.VersionNumber, LatestVersion.VersionNumber "
                f"FROM FlowDefinition WHERE DeveloperName = {_soql_quote(name)}"
            ).get("records", [])
            if not rows:
                continue
            row = rows[0]
            latest = (row.get("LatestVersion") or {}).get("VersionNumber")
            active = (row.get("ActiveVersion") or {}).get("VersionNumber")
            if latest and latest != active:
                self.tooling.FlowDefinition.update(row["Id"], {"Metadata": {"activeVersionNumber": latest}})
                self.logger.info(f"  Flow {name}: activated version {latest}")

    # ------------------------------------------------------------------ sf CLI

    def _init_project(self, work: Path):
        (work / "force-app").mkdir(parents=True, exist_ok=True)
        api = self.project_config.project__package__api_version
        (work / "sfdx-project.json").write_text(
            json.dumps(
                {"packageDirectories": [{"path": "force-app", "default": True}], "sourceApiVersion": api}
            ),
            encoding="utf-8",
        )

    def _retrieve(self, work: Path, members: List[str]):
        cmd = ["sf", "project", "retrieve", "start", "--target-org", self.org_config.username, "--wait", "15", "--json"]
        for m in members:
            cmd += ["--metadata", m]
        self._sf(cmd, work, "retrieve")

    def _deploy(self, work: Path, files: List[Path]):
        cmd = ["sf", "project", "deploy", "start", "--target-org", self.org_config.username, "--wait", "30", "--json"]
        for f in files:
            cmd += ["--source-dir", str(f.relative_to(work))]
        self.logger.info(f"Deploying {len(files)} patched file(s)")
        self._sf(cmd, work, "deploy")

    def _sf(self, cmd: List[str], cwd: Path, what: str) -> dict:
        result = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True)
        out = result.stdout
        try:
            data = json.loads(out[out.index("{"):])
        except ValueError:
            data = {}
        if result.returncode != 0 or data.get("status", 0) != 0:
            details = (data.get("result") or {}).get("details") or {}
            failures = details.get("componentFailures") or []
            failures = failures if isinstance(failures, list) else [failures]
            problems = "; ".join(f"{f.get('fullName')}: {f.get('problem')}" for f in failures)
            raise CommandException(f"sf {what} failed: {problems or data.get('message') or result.stderr[-1500:]}")
        return data


# ---------------------------------------------------------------- XML helpers


def _soql_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def _layout_actions(text: str) -> List[Tuple[str, str]]:
    block = _record_action_list(text)
    if not block:
        return []
    return re.findall(
        r"<platformActionListItems>\s*<actionName>([^<]+)</actionName>\s*<actionType>([^<]+)</actionType>",
        block,
    )


def _layout_fields(text: str) -> List[str]:
    sections = "".join(re.findall(r"<layoutSections>.*?</layoutSections>", text, re.S))
    seen = []
    for f in re.findall(r"<field>([^<]+)</field>", sections):
        if f not in seen:
            seen.append(f)
    return seen


def _record_action_list(text: str) -> Optional[str]:
    for m in re.finditer(r"<platformActionList>.*?</platformActionList>", text, re.S):
        if "<actionListContext>Record</actionListContext>" in m.group(0):
            return m.group(0)
    return None


def _add_layout_actions(text: str, actions: List[Tuple[str, str]]):
    """Put the pest actions first in the Record action list. Returns (text, added) or
    (text, None) when the layout has no Record action list to add to."""
    block = _record_action_list(text)
    if block is None:
        return text, (None if actions else [])
    existing = _layout_actions(block)
    names = {a[0] for a in existing}
    new = [a for a in actions if a[0] not in names]
    if not new:
        return text, []
    indent = re.search(r"\n(\s*)<platformActionListItems>", block)
    pad = indent.group(1) if indent else "        "
    items = "".join(
        f"\n{pad}<platformActionListItems>\n{pad}    <actionName>{n}</actionName>\n"
        f"{pad}    <actionType>{t}</actionType>\n{pad}    <sortOrder>{i}</sortOrder>\n"
        f"{pad}</platformActionListItems>"
        for i, (n, t) in enumerate(new + existing)
    )
    head = re.match(r"<platformActionList>\s*<actionListContext>Record</actionListContext>", block).group(0)
    rebuilt = head + items + "\n" + pad[:-4] + "</platformActionList>"
    return text.replace(block, rebuilt, 1), [n for n, _ in new]


def _add_layout_section(text: str, fields: List[str], label: str):
    present = set(_layout_fields(text))
    missing = [f for f in fields if f not in present]
    if not missing:
        return text, []
    items = "".join(
        f"\n            <layoutItems>\n                <behavior>Edit</behavior>\n"
        f"                <field>{f}</field>\n            </layoutItems>"
        for f in missing
    )
    for m in re.finditer(r"<layoutSections>.*?</layoutSections>", text, re.S):
        if f"<label>{label}</label>" in m.group(0):
            columns_end = text.find("</layoutColumns>", m.start(), m.end())
            if columns_end != -1:
                at = text.rfind("\n", m.start(), columns_end)
                return text[:at] + items + text[at:], missing
    section = (
        "\n    <layoutSections>\n        <customLabel>true</customLabel>\n"
        "        <detailHeading>true</detailHeading>\n        <editHeading>true</editHeading>\n"
        f"        <label>{label}</label>\n        <layoutColumns>{items}\n        </layoutColumns>\n"
        "        <style>OneColumn</style>\n    </layoutSections>"
    )
    # Sections must stay contiguous: insert after the last one, before miniLayout etc.
    end = text.rfind("</layoutSections>")
    if end == -1:
        return text, []
    end += len("</layoutSections>")
    return text[:end] + section + text[end:], missing


def _add_layout_related_lists(text: str, template: str, names: List[str]):
    """Copy the named related lists, with their columns, from the template layout."""
    present = set(re.findall(r"<relatedList>([^<]+)</relatedList>", text))
    blocks = {}
    for m in re.finditer(r"<relatedLists>.*?</relatedLists>", template, re.S):
        name = re.search(r"<relatedList>([^<]+)</relatedList>", m.group(0))
        if name:
            blocks[name.group(1)] = m.group(0)
    new = [n for n in names if n not in present and n in blocks]
    if not new:
        return text, []
    insert = "".join("\n    " + blocks[n] for n in new)
    # relatedLists must stay contiguous: after the last one, else before the elements that follow.
    end = text.rfind("</relatedLists>")
    if end != -1:
        at = end + len("</relatedLists>")
    else:
        later = [m.start() for t in LAYOUT_AFTER_RELATED_LISTS for m in [re.search(rf"\n    <{t}>", text)] if m]
        at = min(later) if later else text.rfind("\n</Layout>")
    return text[:at] + insert + text[at:], new


def _app_record_pages(app_xml: str, sobjects: List[str]) -> Dict[str, str]:
    pages = {}
    for block in re.findall(r"<actionOverrides>.*?</actionOverrides>", app_xml, re.S):
        def tag(name):
            m = re.search(rf"<{name}>([^<]+)</{name}>", block)
            return m.group(1) if m else None

        sobject = tag("pageOrSobjectType")
        if (
            sobject in sobjects
            and tag("actionName") == "View"
            and tag("type") == "Flexipage"
            and tag("formFactor") in (None, "Large")
            and sobject not in pages
        ):
            pages[sobject] = tag("content")
    return pages


def _related_list_item(sobject: str, spec: dict, identifier: str) -> str:
    def prop(name, value=None, values=None):
        if values is not None:
            items = "".join(
                f"\n                        <valueListItems>\n                            <value>{v}</value>"
                "\n                        </valueListItems>"
                for v in values
            )
            return (
                f"\n                <componentInstanceProperties>\n                    <name>{name}</name>"
                f"\n                    <valueList>{items}\n                    </valueList>"
                "\n                </componentInstanceProperties>"
            )
        val = f"\n                    <value>{value}</value>" if value is not None else ""
        return (
            f"\n                <componentInstanceProperties>\n                    <name>{name}</name>{val}"
            "\n                </componentInstanceProperties>"
        )

    sort_field, sort_order = spec["sort"]
    body = "".join([
        prop("actionNames"),
        prop("adminFilters"),
        prop("maxRecordsToDisplay", "10"),
        prop("parentFieldApiName", f"{sobject}.Id"),
        prop("relatedListApiName", spec["api"]),
        prop("relatedListDisplayType", "ADVGRID"),
        prop("relatedListFieldAliases", values=spec["fields"]),
        prop("relatedListLabel", spec["label"]),
        prop("showActionBar", "true"),
        prop("sortFieldAlias", sort_field),
        prop("sortFieldOrder", sort_order),
    ])
    return (
        "\n        <itemInstances>\n            <componentInstance>" + body
        + "\n                <componentName>lst:dynamicRelatedList</componentName>"
        f"\n                <identifier>{identifier}</identifier>"
        "\n            </componentInstance>\n        </itemInstances>"
    )


def _add_related_lists(text: str, sobject: str, specs: List[dict]):
    """Append dynamic related lists to the page's Related tab. Returns (text, added) or
    (text, None) when the page has no Related tab."""
    tab = re.search(
        r"<name>body</name>\s*<value>([^<]+)</value>\s*</componentInstanceProperties>\s*"
        r"<componentInstanceProperties>\s*<name>title</name>\s*<value>Standard\.Tab\.relatedLists</value>",
        text,
    )
    if not tab:
        return text, None
    facet = tab.group(1)
    name_at = text.find(f"<name>{facet}</name>")
    region_start = text.rfind("<flexiPageRegions>", 0, name_at)
    if name_at == -1 or region_start == -1:
        return text, None
    region = text[region_start:name_at]
    existing = set(re.findall(r"<name>relatedListApiName</name>\s*<value>([^<]+)</value>", region))
    new = [s for s in specs if s["api"] not in existing]
    if not new:
        return text, []
    items = "".join(_related_list_item(sobject, s, f"RLM_RTK_{s['api']}") for s in new)
    last_item = region.rfind("</itemInstances>")
    insert_at = region_start + (last_item + len("</itemInstances>") if last_item != -1 else len("<flexiPageRegions>"))
    return text[:insert_at] + items + text[insert_at:], [s["api"] for s in new]


def _add_fault_paths(text: str):
    """Give each Create Records element a fault path to its next element (or to a no-op
    assignment when it is the last), so a failed create doesn't fail the triggering DML."""
    count = 0
    needs_noop = False

    def patch(m):
        nonlocal count, needs_noop
        block = m.group(0)
        if "<faultConnector>" in block:
            return block
        nxt = re.search(r"<connector>\s*<targetReference>([^<]+)</targetReference>\s*</connector>", block)
        # faultConnector sorts after connector, before inputAssignments / object.
        anchor = re.search(r"\n\s*<(filterLogic|filters|inputAssignments|inputReference|object)>", block)
        if not anchor:
            return block
        target = nxt.group(1) if nxt else FAULT_ASSIGNMENT
        needs_noop = needs_noop or not nxt
        # Rejoining the main path needs isGoTo, or auto-layout flows won't open in Flow Builder.
        go_to = "\n            <isGoTo>true</isGoTo>" if nxt else ""
        fault = (
            f"\n        <faultConnector>{go_to}\n            <targetReference>{target}</targetReference>"
            "\n        </faultConnector>"
        )
        count += 1
        return block[: anchor.start()] + fault + block[anchor.start():]

    text = re.sub(r"<recordCreates>.*?</recordCreates>", patch, text, flags=re.S)
    if needs_noop and f"<name>{FAULT_ASSIGNMENT}</name>" not in text:
        assignment = (
            f"    <assignments>\n        <name>{FAULT_ASSIGNMENT}</name>\n"
            "        <label>Continue After Fault</label>\n        <locationX>0</locationX>\n"
            "        <locationY>0</locationY>\n        <assignmentItems>\n"
            f"            <assignToReference>{FAULT_VARIABLE}</assignToReference>\n"
            "            <operator>Add</operator>\n            <value>\n"
            "                <numberValue>1.0</numberValue>\n            </value>\n"
            "        </assignmentItems>\n    </assignments>\n"
        )
        variable = (
            f"    <variables>\n        <name>{FAULT_VARIABLE}</name>\n        <dataType>Number</dataType>\n"
            "        <isCollection>false</isCollection>\n        <isInput>false</isInput>\n"
            "        <isOutput>false</isOutput>\n        <scale>0</scale>\n        <value>\n"
            "            <numberValue>0.0</numberValue>\n        </value>\n    </variables>\n"
        )
        text = _insert_flow_element(text, "assignments", assignment)
        text = _insert_flow_element(text, "variables", variable)
    return text, count


def _insert_flow_element(text: str, tag: str, element: str) -> str:
    last = text.rfind(f"</{tag}>\n")
    if last != -1:
        at = last + len(f"</{tag}>\n")
        return text[:at] + element + text[at:]
    later = FLOW_ELEMENT_ORDER[FLOW_ELEMENT_ORDER.index(tag) + 1:]
    positions = [m.start() for t in later for m in [re.search(rf"^    <{t}>", text, re.M)] if m]
    at = min(positions) if positions else text.rfind("</Flow>")
    return text[:at] + element + text[at:]
