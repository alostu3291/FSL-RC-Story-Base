"""Deploy a metadata path only when a SOQL check finds nothing.

For metadata the platform refuses to redeploy once records use it, such as an
entitlement process ("Cannot update SLA process that is in use").
"""

try:
    from cumulusci.tasks.salesforce import Deploy
except ImportError:
    Deploy = object


class DeployUnlessPresent(Deploy):
    task_options = {
        **getattr(Deploy, "task_options", {}),
        "skip_if_soql": {
            "description": "SOQL query; the deploy is skipped when it returns any rows.",
            "required": True,
        },
    }

    def _run_task(self):
        soql = self.options["skip_if_soql"]
        result = self.org_config.salesforce_client.query(soql)
        if result.get("totalSize", 0) > 0:
            self.logger.info("Already present, skipping deploy of %s (%s)", self.options["path"], soql)
            return
        super()._run_task()
