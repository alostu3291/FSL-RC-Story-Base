#!/usr/bin/env python3
"""
Report what a Salesforce org has of the Rentokil pest / Field Service demo, and what it is missing.

For each metadata bundle it runs a check-only deploy (nothing is saved) and lists components the
org doesn't have yet (Created), components that differ (Changed) and failures. Then it runs SOQL
checks on the demo data and setup the bundles depend on, naming the CCI task that fixes each gap.

Usage:
    python scripts/ai/pest_org_inventory.py --target-org <sf username or alias>
    python scripts/ai/pest_org_inventory.py --target-org <org> --skip-dry-run       # data checks only
    python scripts/ai/pest_org_inventory.py --target-org <org> --bundles post_pest  # one bundle

"Changed" is noisy: some types (OmniDataTransform, Flow, PermissionSet) report Changed even when
identical. "Created" is the reliable signal for something missing.
"""
import argparse
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# (bundle, CCI tasks that deploy it, feature flags it needs)
BUNDLES = [
    ("post_fsl", "deploy_post_fsl (prepare_fsl)", "fsl"),
    ("post_pest_sla", "deploy_post_pest_sla", "pest"),
    ("post_pest", "deploy_post_pest, then assign_permission_sets RLM_Rentokil_Pest", "pest"),
    ("post_pest_ai", "deploy_post_pest_ai, activate_pest_prompt_templates", "pest + einstein"),
    ("post_pest_docgen", "deploy_post_pest_docgen, activate_docgen_templates, fix_pest_document_template_binaries", "pest + docgen"),
    ("post_pest_agent", "deploy_agents_settings, deploy_post_pest_agent, activate_pest_billing_agent", "pest + agents"),
]

# Check-only failures that mean "already there and locked", not a gap.
KNOWN_FAILURES = [
    ("Can't edit an active bot version", "already active; deactivate the agent in Agentforce Builder to update it"),
]

# (label, SOQL count query, minimum expected, fix). {user} is the target org's username.
CHECKS = [
    ("RTK products", "SELECT COUNT() FROM Product2 WHERE StockKeepingUnit LIKE 'RTK-%'", 1,
     "cci task run insert_pest_pcm_data"),
    ("RTK standard price book entries",
     "SELECT COUNT() FROM PricebookEntry WHERE Product2.StockKeepingUnit LIKE 'RTK-%' "
     "AND Pricebook2.IsStandard = true AND IsActive = true", 1,
     "cci task run insert_pest_pricing_data, then setup_rtk_revenue"),
    ("Service zones", "SELECT COUNT() FROM RLM_RTK_Service_Zone__c", 1, "cci task run setup_rtk_revenue"),
    ("Bloomingdale IL territory", "SELECT COUNT() FROM ServiceTerritory WHERE Name = 'Bloomingdale IL' AND IsActive = true", 1,
     "cci task run insert_pest_fsl_data, then setup_rtk_foundation"),
    ("Pest work types",
     "SELECT COUNT() FROM WorkType WHERE Name IN ('Pest Inspection','Pest Re-service','Initial Pest Treatment','Monthly Pest Visit')", 4,
     "cci task run setup_rtk_foundation"),
    ("Running user is a service resource",
     "SELECT COUNT() FROM ServiceResource WHERE RelatedRecord.Username = '{user}' AND IsActive = true", 1,
     "cci task run setup_rtk_foundation (books visits to the running user)"),
    ("RLM_Rentokil_Pest assigned to running user",
     "SELECT COUNT() FROM PermissionSetAssignment WHERE PermissionSet.Name = 'RLM_Rentokil_Pest' AND Assignee.Username = '{user}'", 1,
     "cci task run assign_permission_sets -o api_names RLM_Rentokil_Pest"),
    ("Re-service entitlement process active",
     "SELECT COUNT() FROM SlaProcess WHERE Name = 'Rentokil Re-service Guarantee' AND IsActive = true", 1,
     "cci task run deploy_post_pest_sla"),
    ("Rentokil Service Days business hours",
     "SELECT COUNT() FROM BusinessHours WHERE Name = 'Rentokil Service Days' AND IsActive = true", 1,
     "cci task run deploy_post_pest_sla"),
    ("Active RTK document templates",
     "SELECT COUNT() FROM DocumentTemplate WHERE Name LIKE 'RLM_RTK%' AND IsActive = true", 2,
     "cci task run deploy_post_pest_docgen, activate_docgen_templates, fix_pest_document_template_binaries"),
]

# (label, SOQL count query, fix) where any row is a problem.
PROBLEMS = [
    ("Guarantees without the response process",
     "SELECT COUNT() FROM Entitlement WHERE RLM_RTK_Covered_Pests__c != null AND SlaProcessId = null",
     "Anonymous Apex: RLM_RTK_Coverage.syncAll();"),
]


def sf(args):
    proc = subprocess.run(["sf"] + args + ["--json"], cwd=REPO, capture_output=True, text=True)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"status": 1, "message": (proc.stderr or proc.stdout).strip()[:500]}


def count(org, soql):
    result = sf(["data", "query", "--target-org", org, "-q", soql])
    if result.get("status") != 0:
        return None, result.get("message", "query failed")
    return result["result"]["totalSize"], None


def dry_run(org, bundle):
    result = sf([
        "project", "deploy", "start", "--dry-run", "--source-dir", f"unpackaged/{bundle}",
        "--target-org", org, "--test-level", "NoTestRun", "--wait", "60",
    ])
    data = result.get("result") or (result.get("data") or {})
    files = data.get("files") or []
    failures = ((data.get("details") or {}).get("componentFailures")) or []
    if isinstance(failures, dict):
        failures = [failures]
    if not files and not failures and result.get("status") != 0:
        failures = [{"fullName": bundle, "problem": result.get("message", "deploy check failed")}]
    return files, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target-org", required=True, help="sf CLI username or alias (not a CCI alias)")
    parser.add_argument("--bundles", nargs="*", help="Only these bundles, e.g. post_pest post_pest_sla")
    parser.add_argument("--skip-dry-run", action="store_true", help="Data checks only")
    args = parser.parse_args()

    org_info = sf(["org", "display", "--target-org", args.target_org])
    if org_info.get("status") != 0:
        sys.exit(f"Can't reach org {args.target_org}: {org_info.get('message')}")
    user = org_info["result"]["username"]
    print(f"Org: {user} ({org_info['result'].get('instanceUrl')})\n")

    gaps = 0
    if not args.skip_dry_run:
        sla_present, _ = count(args.target_org, CHECKS[7][1])
        for bundle, tasks, flags in BUNDLES:
            if args.bundles and bundle not in args.bundles:
                continue
            if bundle == "post_pest_sla" and sla_present:
                print(f"== {bundle}: entitlement process already active; skipped (an in-use process can't be redeployed)\n")
                continue
            files, failures = dry_run(args.target_org, bundle)
            created = sorted(f"{f['type']} {f['fullName']}" for f in files if f.get("state") == "Created")
            changed = [f for f in files if f.get("state") == "Changed"]
            unchanged = [f for f in files if f.get("state") == "Unchanged"]
            print(f"== {bundle}  (deploy: {tasks}; flags: {flags})")
            print(f"   {len(created)} missing, {len(changed)} changed, {len(unchanged)} unchanged, {len(failures)} failing")
            for name in created:
                print(f"   + {name}")
            for f in failures:
                problem = f.get("problem") or ""
                note = next((n for text, n in KNOWN_FAILURES if text in problem), None)
                mark = "~" if note else "!"
                print(f"   {mark} {f.get('componentType', '')} {f.get('fullName')}: {problem}" + (f" ({note})" if note else ""))
                gaps += 0 if note else 1
            gaps += len(created)
            print()

    print("== Data and setup")
    for label, soql, minimum, fix in CHECKS:
        n, error = count(args.target_org, soql.format(user=user))
        if error:
            print(f"   ? {label}: {error[:160]}")
            gaps += 1
        elif n < minimum:
            print(f"   ✗ {label}: {n} (need {minimum}) → {fix}")
            gaps += 1
        else:
            print(f"   ✓ {label}: {n}")
    for label, soql, fix in PROBLEMS:
        n, error = count(args.target_org, soql)
        if error:
            print(f"   ? {label}: {error[:160]}")
        elif n:
            print(f"   ✗ {label}: {n} → {fix}")
            gaps += 1
        else:
            print(f"   ✓ {label}: none")
    print(f"\n{gaps} gap(s) found." if gaps else "\nNothing missing.")


if __name__ == "__main__":
    main()
