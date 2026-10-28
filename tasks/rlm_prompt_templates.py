"""
CumulusCI tasks for Einstein prompt templates and Agentforce agents.

ActivatePromptTemplates
    A metadata deploy of GenAiPromptTemplate leaves the new version inactive, even
    with "deploy prompt templates as active" on, and Apex calls to an inactive
    template fail with "No active template version". This task activates the
    latest version of each template in a directory through the Einstein REST API.

ActivateAgents
    Activates deployed Agentforce agents (Bot) with `sf agent activate`.
"""
import glob
import os
import subprocess

try:
    from cumulusci.tasks.salesforce import BaseSalesforceApiTask
    from cumulusci.core.exceptions import TaskOptionsError, CommandException
except ImportError:
    BaseSalesforceApiTask = object
    TaskOptionsError = Exception
    CommandException = Exception

TEMPLATE_SUFFIX = ".genAiPromptTemplate-meta.xml"


class ActivatePromptTemplates(BaseSalesforceApiTask):
    """Activate the latest version of every prompt template in templates_dir."""

    task_options = {
        "templates_dir": {
            "description": "Directory of .genAiPromptTemplate-meta.xml files to activate.",
            "required": True,
        },
    }

    def _run_task(self):
        templates_dir = self.options["templates_dir"]
        names = sorted(
            os.path.basename(path)[: -len(TEMPLATE_SUFFIX)]
            for path in glob.glob(os.path.join(templates_dir, "*" + TEMPLATE_SUFFIX))
        )
        if not names:
            raise TaskOptionsError(f"No prompt templates found in {templates_dir}")

        failed = []
        for name in names:
            template = self.sf.restful(f"einstein/prompt-templates/{name}")
            versions = template["childRelationships"]["GenAiPromptTemplateVersions"]
            latest = max(
                versions,
                key=lambda v: (v["fields"].get("VersionNumber") or {}).get("value") or 0,
            )
            version_id = latest["fields"]["Id"]["value"]
            if (template["fields"].get("ActiveVersionId") or {}).get("value") == version_id:
                self.logger.info(f"{name}: latest version already active")
                continue
            result = self.sf.restful(
                f"einstein/prompt-templates/{name}/versions/{version_id}/status",
                method="PUT",
                params={"action": "activate", "ignoreWarnings": "true"},
                data="{}",
            )
            if result.get("isSuccessful"):
                self.logger.info(f"{name}: activated")
            else:
                failed.append(name)
                self.logger.error(f"{name}: {result.get('errorMessages')}")
        if failed:
            raise CommandException(f"Could not activate: {', '.join(failed)}")


class ActivateAgents(BaseSalesforceApiTask):
    """Activate Agentforce agents with `sf agent activate`."""

    task_options = {
        "api_names": {
            "description": "Comma-separated Bot API names to activate.",
            "required": True,
        },
    }

    def _run_task(self):
        names = self.options["api_names"]
        if isinstance(names, str):
            names = [n.strip() for n in names.split(",") if n.strip()]
        for name in names:
            completed = subprocess.run(
                [
                    "sf", "agent", "activate",
                    "--api-name", name,
                    "--target-org", self.org_config.username,
                ],
                capture_output=True,
                text=True,
            )
            if completed.returncode != 0:
                raise CommandException(f"{name}: {completed.stderr.strip() or completed.stdout.strip()}")
            self.logger.info(completed.stdout.strip().splitlines()[-1] if completed.stdout.strip() else f"{name}: activated")
