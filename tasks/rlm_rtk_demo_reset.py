"""
Reset the Verdant Field Assistant (LLM) demo so it can be run again with the same scripted caller.

Archives the accounts the assistant created for the caller (Account.RLM_RTK_Demo_Run__c is set):
they're renamed "zz Archived - <name> (<when>)" and their open visits are canceled, so the next call
books a brand-new customer. Orders, assets and invoices stay as history. Then re-seeds the backup
customers through seed_rtk_demo_cast, so a scene can be shown on an existing customer if the live
run goes off script.

Usage:
    cci task run reset_verdant_llm_demo --org verdant
    cci task run reset_verdant_llm_demo --org verdant -o customer "Sarah Mitchell" -o reseed false
"""

try:
    from cumulusci.core.exceptions import CommandException
except ImportError:
    CommandException = Exception

from tasks.rlm_rtk_seed_cast import SeedRtkDemoCast

BACKUPS = "Aisha Brooks,Casey Morgan,Sam Patel,Dana Whitfield"


class ResetVerdantLlmDemo(SeedRtkDemoCast):
    """Archives the scripted caller's demo runs, then re-seeds the backup cast."""

    task_options = {
        "customer": {"description": "The scripted caller to archive. Defaults to Sarah Mitchell.", "required": False},
        "reseed": {"description": "Re-seed the backup customers afterwards. Defaults to true.", "required": False},
        **SeedRtkDemoCast.task_options,
    }
    task_options["customers"] = {
        "description": f"Backup customers to re-seed. Defaults to {BACKUPS}.", "required": False,
    }

    def _init_options(self, kwargs):
        super()._init_options(kwargs)
        self.options["customer"] = (self.options.get("customer") or "Sarah Mitchell").strip()
        self.options["reseed"] = str(self.options.get("reseed", "true")).lower() != "false"
        self.options["customers"] = self.options.get("customers") or BACKUPS

    def _run_task(self):
        response = self.sf.apexecute(
            "verdant/assistant", method="POST",
            data={"operation": "resetDemo", "params": {"customerName": self.options["customer"]}},
        )
        if not response.get("success"):
            raise CommandException(f"Reset failed: {response.get('error')}")
        result = response["result"]
        archived = result.get("archived") or []
        if archived:
            for name in archived:
                self.logger.info(f"Archived {name}")
            self.logger.info(
                f"Canceled {result.get('workOrdersCanceled', 0)} open work orders and "
                f"{result.get('appointmentsCanceled', 0)} appointments"
            )
        else:
            self.logger.info(f"No assistant-created {self.options['customer']} to archive")
        for problem in result.get("problems") or []:
            self.logger.warning(problem)

        if self.options["reseed"]:
            self.logger.info("")
            self.logger.info(f"Re-seeding backup customers: {self.options['customers']}")
            super()._run_task()
