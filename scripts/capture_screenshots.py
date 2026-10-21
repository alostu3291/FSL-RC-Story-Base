"""Run the QuantumBit Revenue Cloud + Field Service story on fsl-rc and capture each scene."""
import json, os, re, subprocess, sys, tempfile, time, datetime
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Checkout of the Revenue Cloud Base Foundations repo (provides scripts/place_fsl_demo_order.py).
REPO = os.environ.get("RLM_REPO", os.path.join(os.path.dirname(ROOT), "rlm-base-dev"))
OUT = os.path.join(ROOT, "screenshots")
STATE = os.path.join(OUT, "story-records.json")
ORG = os.environ.get("FSL_ORG", "fsl-rc")
os.makedirs(OUT, exist_ok=True)
state = json.load(open(STATE)) if os.path.exists(STATE) else {}


def save_state():
    json.dump(state, open(STATE, "w"), indent=2)


def sf(*args):
    r = subprocess.run(["sf", *args, "--target-org", ORG], capture_output=True, text=True)
    return r.stdout


def q(soql):
    out = json.loads(sf("data", "query", "-q", soql, "--json") or "{}")
    if "result" not in out:
        print("QUERY FAILED", soql, out.get("message"))
        return []
    return out["result"]["records"]


def q1(soql):
    rows = q(soql)
    return rows[0] if rows else None


def update(sobject, rid, values):
    out = sf("data", "update", "record", "-s", sobject, "-i", rid, "-v", values, "--json")
    if '"status": 0' not in out:
        print("UPDATE FAILED", sobject, rid, out[:400])


def apex(code):
    with tempfile.NamedTemporaryFile("w", suffix=".apex", delete=False) as fh:
        fh.write(code)
    out = sf("apex", "run", "-f", fh.name)
    m = re.findall(r"USER_DEBUG\|\[\d+\]\|DEBUG\|(.*)", out)
    if "Error" in out and not m:
        print("APEX FAILED", out[-800:])
    return m


def rest(path, body):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(body, fh)
    return sf("api", "request", "rest", f"/services/data/v66.0{path}", "--method", "POST", "--body", f"@{fh.name}")


def wait_for(fn, timeout=240, interval=10):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(interval)
    return None


# ---------------------------------------------------------------- browser
info = json.loads(subprocess.run(["sf", "org", "open", "--url-only", "--json", "--target-org", ORG],
                                 capture_output=True, text=True).stdout)
login_url = info["result"]["url"]
base = login_url.split("/secur/")[0].replace(".my.salesforce.com", ".lightning.force.com")
opts = webdriver.ChromeOptions()
for a in ["--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
          f"--user-data-dir={tempfile.mkdtemp()}", "--disable-notifications", "--window-size=1600,1100"]:
    opts.add_argument(a)
opts.browser_version = "140"
d = webdriver.Chrome(options=opts)
d.set_window_size(1600, 1100)
d.get(login_url)
time.sleep(12)

DEEP = """
const mode = arguments[0], label = (arguments[1] || '').toLowerCase();
function walk(root, out) {
  root.querySelectorAll('*').forEach(el => {
    if (el.shadowRoot) walk(el.shadowRoot, out);
    out.push(el);
  });
  return out;
}
const all = walk(document, []).filter(e => e.offsetParent !== null || e.getClientRects().length);
const text = e => (e.textContent || '').trim().toLowerCase();
let hits = [];
if (mode === 'tab') hits = all.filter(e => (e.getAttribute('role') === 'tab' || e.getAttribute('data-tab-value')) && text(e) === label);
if (mode === 'button') hits = all.filter(e => (e.tagName === 'BUTTON' || e.getAttribute('role') === 'button' || e.tagName === 'A') && (text(e) === label || (e.getAttribute('title') || '').toLowerCase() === label));
function inFlow(e) {
  let n = e;
  while (n) {
    if (n.tagName && n.tagName.startsWith('FLOWRUNTIME')) return true;
    n = n.parentNode || (n.getRootNode && n.getRootNode().host) || null;
    if (n === document) return false;
  }
  return false;
}
if (mode === 'textarea') hits = all.filter(e => e.tagName === 'TEXTAREA' && inFlow(e));
if (mode === 'input') hits = all.filter(e => e.tagName === 'INPUT' && e.type !== 'hidden' && e.type !== 'checkbox' && inFlow(e));
if (mode === 'flowbutton') hits = all.filter(e => e.tagName === 'BUTTON' && inFlow(e) && text(e) === label);
return hits;
"""


def settle(extra=6):
    end = time.time() + 40
    while time.time() < end:
        spin = d.find_elements(By.CSS_SELECTOR, ".slds-spinner_container:not(.slds-hide), lightning-spinner")
        if d.execute_script("return document.readyState") == "complete" and not [s for s in spin if s.is_displayed()]:
            break
        time.sleep(1)
    time.sleep(extra)


def shot(name, tall=False):
    if tall:
        d.set_window_size(1600, 3200)
        settle(6)
    path = os.path.join(OUT, name + ".png")
    d.save_screenshot(path)
    print("saved", name)
    if tall:
        d.set_window_size(1600, 1100)


def deep(mode, label=""):
    return d.execute_script(DEEP, mode, label)


def click(mode, label, wait=6):
    hits = deep(mode, label)
    if not hits:
        print("  not found:", mode, label)
        return False
    d.execute_script("arguments[0].click()", hits[0])
    settle(wait)
    return True


def visit(name, sobject, rid, tab=None, tall=False, wait=8):
    d.get(f"{base}/lightning/r/{sobject}/{rid}/view")
    settle(wait)
    if tab:
        click("tab", tab, 8)
    shot(name, tall)


def run_scene(n):
    return n in SCENES


SCENES = set(sys.argv[1].split(",")) if len(sys.argv) > 1 else {"1", "2", "3", "4", "5", "6", "7", "8", "9"}

# ---------------------------------------------------------------- scene 1: quote
if run_scene("1") and os.environ.get("REUSE_ORDER"):
    o = q1("SELECT Id, OrderNumber, AccountId, QuoteId, Quote.OpportunityId FROM Order WHERE OrderNumber = '%s'" % os.environ["REUSE_ORDER"])
    state["order"], state["order_number"], state["account"] = o["Id"], o["OrderNumber"], o["AccountId"]
    state["quote"] = o["QuoteId"]
    state["opportunity"] = q1("SELECT OpportunityId FROM Quote WHERE Id = '%s'" % o["QuoteId"])["OpportunityId"]
    save_state()
    visit("s1-01-opportunity", "Opportunity", state["opportunity"])
    visit("s1-02-quote", "Quote", state["quote"], wait=12)
    visit("s1-03-quote-lines", "Quote", state["quote"], tab="Related", tall=True)
    visit("s1-04-order", "Order", state["order"], wait=12)
elif run_scene("1"):
    r = subprocess.run(["python3", "scripts/place_fsl_demo_order.py", "--target-org", ORG], cwd=REPO, capture_output=True, text=True)
    print(r.stdout[-800:], r.stderr[-800:])
    state["opportunity"] = re.search(r"Opportunity created: (\w+)", r.stdout).group(1)
    state["quote"] = re.search(r"Quote placed: (\w+)", r.stdout).group(1)
    m = re.search(r"Order (\d+) created: (\w+)", r.stdout)
    state["order_number"], state["order"] = m.group(1), m.group(2)
    state["account"] = q1("SELECT AccountId FROM Order WHERE Id = '%s'" % state["order"])["AccountId"]
    save_state()
    visit("s1-01-opportunity", "Opportunity", state["opportunity"])
    visit("s1-02-quote", "Quote", state["quote"], wait=12)
    visit("s1-03-quote-lines", "Quote", state["quote"], tab="Related", tall=True)
    visit("s1-04-order", "Order", state["order"], wait=12)

# ---------------------------------------------------------------- scene 2: fulfillment plan + ship
if run_scene("2"):
    plan = wait_for(lambda: q1("SELECT Id FROM FulfillmentPlan WHERE SourceIdentifier = '%s'" % state["order"]))
    state["plan"] = plan["Id"]
    save_state()
    visit("s2-01-order-fulfillment-ship-pending", "Order", state["order"], tab="Fulfillment", tall=True, wait=12)
    visit("s2-02-fulfillment-plan", "FulfillmentPlan", state["plan"], wait=12)
    ship = wait_for(lambda: q1("SELECT Id FROM FulfillmentStep WHERE FulfillmentPlanId = '%s' AND Name = 'Ship Hardware' AND State = 'InProgress'" % state["plan"]))
    update("FulfillmentStep", ship["Id"], "State=Completed")
    state["ship_step"] = ship["Id"]
    wo = wait_for(lambda: q1("SELECT Id, WorkOrderNumber, AssetId FROM WorkOrder WHERE RLM_Order__c = '%s'" % state["order"]))
    state["install_wo"], state["install_wo_number"], state["asset"] = wo["Id"], wo["WorkOrderNumber"], wo["AssetId"]
    save_state()
    print("install WO", wo)

# ---------------------------------------------------------------- scene 3: work order + appointment
if run_scene("3"):
    sa = q1("SELECT Id, AppointmentNumber FROM ServiceAppointment WHERE ParentRecordId = '%s'" % state["install_wo"])
    state["install_sa"], state["install_sa_number"] = sa["Id"], sa["AppointmentNumber"]
    save_state()
    visit("s3-01-install-work-order", "WorkOrder", state["install_wo"])
    visit("s3-02-service-appointment", "ServiceAppointment", state["install_sa"])
    visit("s3-03-order-work-orders", "Order", state["order"], tab="Fulfillment", tall=True, wait=12)

# ---------------------------------------------------------------- scene 4: dispatch + serial number
if run_scene("4"):
    apex("""
ServiceAppointment sa = [SELECT Id FROM ServiceAppointment WHERE Id = '%s'];
ServiceResource tech = [SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1];
Datetime start = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(9, 0, 0, 0));
sa.SchedStartTime = start; sa.SchedEndTime = start.addHours(4); sa.Status = 'Scheduled';
update sa;
if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id] == 0) {
    insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = tech.Id);
}
System.debug('scheduled');
""" % state["install_sa"])
    visit("s4-01-appointment-scheduled", "ServiceAppointment", state["install_sa"])
    visit("s4-02-appointment-assigned-resource", "ServiceAppointment", state["install_sa"], tab="Related", tall=True)
    update("Asset", state["asset"], "SerialNumber=PSR750-SF-24601")
    visit("s4-03-asset-serial-number", "Asset", state["asset"], wait=12)

# ---------------------------------------------------------------- scene 5: milestone billing
if run_scene("5"):
    oi = q1("SELECT Id FROM OrderItem WHERE OrderId = '%s' AND Product2.StockKeepingUnit = 'QB-BDL-R750'" % state["order"])
    bs = q1("SELECT Id FROM BillingSchedule WHERE ReferenceEntityItemId = '%s'" % oi["Id"])
    state["r750_billing_schedule"] = bs["Id"]
    save_state()
    visit("s5-01-billing-waiting-for-install", "BillingSchedule", bs["Id"])
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    state["install_completed_at"] = now
    update("ServiceAppointment", state["install_sa"], f"Status=Completed ActualStartTime={now} ActualEndTime={now}")
    update("WorkOrder", state["install_wo"], "Status=Completed")
    inv = wait_for(lambda: q1("SELECT Id, DocumentNumber, TotalAmount FROM Invoice WHERE BillingAccountId = '%s' AND CreatedDate >= %s AND TotalAmount > 1200 ORDER BY CreatedDate DESC" % (state["account"], now)), 300, 15)
    state["install_invoice"], state["install_invoice_number"] = inv["Id"], inv["DocumentNumber"]
    save_state()
    visit("s5-02-work-order-completed", "WorkOrder", state["install_wo"])
    visit("s5-03-order-fulfillment-complete", "FulfillmentPlan", state["plan"], wait=12)
    visit("s5-04-billing-ready", "BillingSchedule", bs["Id"])
    visit("s5-05-invoice-posted", "Invoice", inv["Id"], wait=12)
    visit("s5-06-invoice-lines", "Invoice", inv["Id"], tab="Related", tall=True)

if run_scene("5p"):
    visit("s5-03-order-fulfillment-complete", "FulfillmentPlan", state["plan"], wait=12)

# ---------------------------------------------------------------- scene 6: maintenance plan
if run_scene("6"):
    mp = wait_for(lambda: q1("SELECT Id, MaintenancePlanNumber FROM MaintenancePlan WHERE Id IN (SELECT MaintenancePlanId FROM MaintenanceAsset WHERE AssetId = '%s')" % state["asset"]), 120)
    state["maintenance_plan"], state["maintenance_plan_number"] = mp["Id"], mp["MaintenancePlanNumber"]
    save_state()
    visit("s6-01-maintenance-plan", "MaintenancePlan", mp["Id"])
    rest("/actions/standard/generateWorkOrders", {"inputs": [{"recordId": mp["Id"]}]})
    wait_for(lambda: q("SELECT Id FROM WorkOrder WHERE MaintenancePlanId = '%s'" % mp["Id"]), 120)
    time.sleep(10)
    visit("s6-02-maintenance-work-orders", "MaintenancePlan", mp["Id"], tab="Related", tall=True)
    pm = q1("SELECT Id FROM WorkOrder WHERE MaintenancePlanId = '%s' ORDER BY SuggestedMaintenanceDate" % mp["Id"])
    state["pm_wo"] = pm["Id"]
    save_state()
    visit("s6-03-preventive-work-order", "WorkOrder", pm["Id"])

# ---------------------------------------------------------------- scene 7: break/fix coverage
if run_scene("7"):
    UNCOVERED_ACCOUNT = "Apex Dynamics"
    find_other = lambda: q1("SELECT Id, AccountId FROM Asset WHERE Account.Name = '%s' AND Product2.StockKeepingUnit = 'QB-BDL-R750' AND Id NOT IN (SELECT AssetId FROM Entitlement WHERE AssetId != null) ORDER BY CreatedDate LIMIT 1" % UNCOVERED_ACCOUNT)
    other = find_other()
    if not other:
        r = subprocess.run(["python3", "scripts/place_fsl_demo_order.py", "--target-org", ORG, "--account-name", UNCOVERED_ACCOUNT, "--no-support"], cwd=REPO, capture_output=True, text=True)
        print(r.stdout[-600:], r.stderr[-600:])
        other = wait_for(find_other, 240)
    state["uncovered_asset"], state["uncovered_account"] = other["Id"], other["AccountId"]
    ids = apex("""
WorkType bf = [SELECT Id FROM WorkType WHERE Name = 'Hardware Break/Fix' LIMIT 1];
ServiceTerritory t = [SELECT Id FROM ServiceTerritory WHERE Name = 'QuantumBit San Francisco' LIMIT 1];
WorkOrder covered = new WorkOrder(AccountId = '%(acct)s', AssetId = '%(asset)s', WorkTypeId = bf.Id, ServiceTerritoryId = t.Id,
    Subject = 'Replace failed drive - Rack 3', Priority = 'High');
WorkOrder uncovered = new WorkOrder(AccountId = '%(other_acct)s', AssetId = '%(other)s', WorkTypeId = bf.Id, ServiceTerritoryId = t.Id,
    Subject = 'Replace failed power supply - Rack 1', Priority = 'High');
insert new List<WorkOrder>{ covered, uncovered };
System.debug(covered.Id + ',' + uncovered.Id);
""" % {"acct": state["account"], "asset": state["asset"], "other": other["Id"], "other_acct": other["AccountId"]})
    state["covered_wo"], state["uncovered_wo"] = ids[0].split(",")
    save_state()
    visit("s7-01-break-fix-covered", "WorkOrder", state["covered_wo"])
    visit("s7-02-break-fix-not-covered", "WorkOrder", state["uncovered_wo"])
    update("WorkOrder", state["covered_wo"], "Status=Completed")
    update("WorkOrder", state["uncovered_wo"], "Status=Completed")
    billed = wait_for(lambda: q1("SELECT RLM_Billable_Order__c FROM WorkOrder WHERE Id = '%s' AND RLM_Billable_Order__c != null" % state["uncovered_wo"]), 180, 15)
    state["repair_order"] = billed["RLM_Billable_Order__c"]
    inv = wait_for(lambda: q1("SELECT Id, DocumentNumber FROM Invoice WHERE BillingAccountId = '%s' AND CreatedDate >= %s AND TotalAmount = 1200 ORDER BY CreatedDate DESC" % (state["uncovered_account"], state["install_completed_at"])), 240, 15)
    state["repair_invoice"] = inv["Id"]
    save_state()
    visit("s7-03-uncovered-completed-billable-order", "WorkOrder", state["uncovered_wo"])
    visit("s7-04-repair-order", "Order", state["repair_order"], wait=12)
    visit("s7-05-repair-invoice", "Invoice", inv["Id"], wait=12)

if run_scene("7b"):
    billed = wait_for(lambda: q1("SELECT RLM_Billable_Order__c FROM WorkOrder WHERE Id = '%s' AND RLM_Billable_Order__c != null" % state["uncovered_wo"]), 180, 15)
    state["repair_order"] = billed["RLM_Billable_Order__c"]
    inv = wait_for(lambda: q1("SELECT Id, DocumentNumber FROM Invoice WHERE BillingAccountId = '%s' AND TotalAmount = 1200 AND Status = 'Posted' ORDER BY CreatedDate DESC" % state["uncovered_account"]), 300, 15)
    state["repair_invoice"] = inv["Id"]
    save_state()
    visit("s7-03-uncovered-completed-billable-order", "WorkOrder", state["uncovered_wo"])
    visit("s7-04-repair-order", "Order", state["repair_order"], wait=12)
    visit("s7-05-repair-invoice", "Invoice", inv["Id"], wait=12)

# ---------------------------------------------------------------- scene 8: flag expansion
if run_scene("8"):
    d.get(f"{base}/lightning/r/WorkOrder/{state['install_wo']}/view")
    settle(10)
    if click("button", "flag expansion", 10):
        areas = deep("textarea")
        if areas:
            areas[0].send_keys("Customer is out of rack space in Row C and plans 4 more PowerSwerve R750 servers next quarter.")
        else:
            print("  no flow textarea")
        inputs = deep("input")
        if inputs:
            inputs[-1].send_keys("16000")
        settle(2)
        shot("s8-01-flag-expansion-action")
        click("flowbutton", "flag expansion", 10)
        shot("s8-02-flag-expansion-confirmation")
        click("flowbutton", "finish", 6)
    opp = wait_for(lambda: q1("SELECT Id, Name FROM Opportunity WHERE RLM_Source_Work_Order__c = '%s' ORDER BY CreatedDate DESC" % state["install_wo"]), 60, 5)
    if opp:
        state["expansion_opportunity"] = opp["Id"]
        save_state()
        visit("s8-03-expansion-opportunity", "Opportunity", opp["Id"])
    visit("s8-04-account-assets-amend", "Account", state["account"], tab="Assets", wait=15, tall=True)

# ---------------------------------------------------------------- scene 9: asset 360
if run_scene("9"):
    visit("s9-01-asset-details", "Asset", state["asset"], wait=12)
    visit("s9-02-asset-related", "Asset", state["asset"], tab="Related", tall=True)
    visit("s9-03-account-related", "Account", state["account"], tab="Related", tall=True)

d.quit()
print(json.dumps(state, indent=2))
