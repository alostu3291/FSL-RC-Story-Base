"""
Seed Brightline HVAC demo visits: a new prospect's system check or a covered No-Cool / No-Heat Call.

Runs an Apex script whose ``%%%NAME%%%`` tokens are filled from task options
(``account_name`` fills ``%%%ACCOUNT_NAME%%%``). Values are escaped for Apex
string literals. After the script runs, the task reports the work order and
appointment it booked, plus the covering agreement, priority and response
milestone for a service call, so a bad seed shows up in the task output.

Usage:
    cci task run seed_hvac_prospect_check --org hvac \
        -o account_name "Priya Raman" -o street "1240 Aurora Ave" -o hour 15
    cci task run seed_hvac_service_call --org hvac \
        -o account_name "Marcus Bell" -o issue "No Cool" -o hour 8
    cci task run seed_hvac_commercial_service_call --org hvac -o hour next

``hour next`` books the next full hour on the territory's clock (Central).
``prelude`` names a script run before ``path`` in the same transaction.
"""

from datetime import datetime
from zoneinfo import ZoneInfo

try:
    from cumulusci.core.exceptions import CommandException
except ImportError:
    CommandException = Exception

from tasks.rlm_rtk_seed_visit import SeedRtkVisit, _apex_string

SERVICE_CALL = "No-Cool / No-Heat Call"
TERRITORY_ZONE = "America/Chicago"


class SeedHvacVisit(SeedRtkVisit):
    """Runs an HVAC seeding script with named tokens, then reports what it booked."""

    task_options = {
        **{k: v for k, v in SeedRtkVisit.task_options.items() if k not in ("pest", "street", "require_coverage")},
        "street": {"description": "Street for a new prospect (Naperville, IL 60540).", "required": False},
        "issue": {
            "description": "Reported issue for a service call: No Cool, No Heat, Noise, Water Leak, "
            "Thermostat, Air Quality or Water Heater.",
            "required": False,
        },
        "require_coverage": {
            "description": "Service call only: fail unless an agreement covers the issue. Defaults to true.",
            "required": False,
        },
        "prelude": {
            "description": "Apex script run before path, in the same transaction (same %%%...%%% tokens).",
            "required": False,
        },
    }

    DEFAULTS = {
        "street": "",
        "phone": "",
        "issue": "",
        "subject": "",
        "description": "",
        "hour": "10",
        "days_ahead": "1",
        "require_coverage": "true",
    }

    def _validate_options(self):
        if str(self.options.get("hour", "")).lower() == "next":
            now = datetime.now(ZoneInfo(TERRITORY_ZONE))
            if now.hour >= 22:
                self.options["hour"] = "8"
                self.options["days_ahead"] = str(int(self.options.get("days_ahead", 0)) + 1)
            else:
                self.options["hour"] = str(now.hour + 1)
        super()._validate_options()

    def _process_apex_from_path(self, apex_path):
        apex = super()._process_apex_from_path(apex_path)
        prelude = self.options.get("prelude")
        if not prelude:
            return apex
        return super()._process_apex_from_path(prelude) + "\n" + apex

    def _report(self):
        name = _apex_string(self.options["account_name"])
        records = self.sf.query(
            "SELECT Id, WorkOrderNumber, WorkType.Name, Status, Priority, Entitlement.Name, "
            "(SELECT AppointmentNumber, Status, SchedStartTime FROM ServiceAppointments ORDER BY CreatedDate) "
            f"FROM WorkOrder WHERE Account.Name = '{name}' ORDER BY LastModifiedDate DESC LIMIT 1"
        )["records"]
        if not records:
            raise CommandException(f"No work order found for {self.options['account_name']} after seeding")
        wo = records[0]
        appointments = (wo.get("ServiceAppointments") or {}).get("records", [])
        self.logger.info(f"{self.options['account_name']}: {wo['WorkType']['Name']}")
        self.logger.info(f"  Work order {wo['WorkOrderNumber']} ({wo['Status']})")
        for sa in appointments:
            self.logger.info(f"  Appointment {sa['AppointmentNumber']} {sa['Status']}")
            self.logger.info(f"  Starts {sa['SchedStartTime']} UTC")
        if wo["WorkType"]["Name"] != SERVICE_CALL:
            return
        agreement = (wo.get("Entitlement") or {}).get("Name")
        milestones = self.sf.query(
            "SELECT MilestoneType.Name, TargetDate FROM EntityMilestone "
            f"WHERE ParentEntityId = '{wo['Id']}' AND IsCompleted = false"
        )["records"]
        self.logger.info(f"  Covered by: {agreement or 'nothing (Not Covered)'}")
        self.logger.info(f"  Priority: {wo.get('Priority') or 'none'}")
        for m in milestones:
            self.logger.info(f"  {m['MilestoneType']['Name']} due {m['TargetDate']} UTC")
        if agreement and not milestones:
            self.logger.warning(
                "  Covered, but no open response milestone. Deploy the SLA bundle (deploy_post_hvac_sla) "
                "and check the agreement's entitlement process."
            )
