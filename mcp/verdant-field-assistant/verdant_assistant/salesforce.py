"""
Client for the Verdant Field Assistant REST facade (POST /services/apexrest/verdant/assistant).

Authenticates through the sf CLI (`sf org display --json`) against an org the CLI already knows, so
no credentials live in this server. The access token is only sent to the REST API. Every call is
appended to a JSONL execution trace that the presenter (or the phase 2 trace panel) can replay.
"""

import asyncio
import datetime
import json
import os
import re
import time
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
from mcp.server.mcpserver.exceptions import ToolError

ENDPOINT = "/services/apexrest/verdant/assistant"
# The Bloomingdale IL territory's clock; every visit time is on it.
CENTRAL = ZoneInfo("America/Chicago")
ISO_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
TRACE_LIMIT = 2000


class Refused(ToolError):
    """Salesforce declined the operation; the message is written for the customer-facing assistant."""


class Unavailable(ToolError):
    """Salesforce couldn't be reached or signed in to; the message says how to fix it."""


def today_central() -> datetime.date:
    return datetime.datetime.now(CENTRAL).date()


def central_label(value: str) -> str:
    stamp = datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    return stamp.astimezone(CENTRAL).strftime("%a %b %-d, %-I:%M %p Central")


def with_local_times(value):
    """Adds a <key>Local label next to every UTC timestamp, so the assistant never converts time zones."""
    if isinstance(value, list):
        return [with_local_times(v) for v in value]
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            out[key] = with_local_times(item)
            if isinstance(item, str) and ISO_UTC.match(item):
                out[f"{key}Local"] = central_label(item)
        return out
    return value


class Salesforce:
    def __init__(self, org: str, trace_path: Path):
        self.org = org
        self.trace_path = trace_path
        self._token = None
        self._instance = None
        self._client = httpx.AsyncClient(timeout=120)

    async def _authenticate(self):
        process = await asyncio.create_subprocess_exec(
            "sf", "org", "display", "--target-org", self.org, "--json",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await process.communicate()
        try:
            result = json.loads(stdout)["result"]
            self._token, self._instance = result["accessToken"], result["instanceUrl"].rstrip("/")
        except (ValueError, KeyError) as e:
            raise Unavailable(
                f"Couldn't sign in to Salesforce org '{self.org}' through the sf CLI. "
                f"Run `sf org login web --alias {self.org}` and try again."
            ) from e

    @property
    def instance_url(self):
        return self._instance

    async def call(self, tool: str, operation: str, params: dict):
        if self._token is None:
            await self._authenticate()
        started = time.monotonic()
        body = {"operation": operation, "params": {k: v for k, v in params.items() if v is not None}}
        response = await self._post(body)
        if response.status_code == 401:
            await self._authenticate()
            response = await self._post(body)
        if response.status_code != 200:
            self._trace(tool, operation, body["params"], started, error=f"HTTP {response.status_code}")
            raise Unavailable(f"Salesforce returned HTTP {response.status_code}: {response.text[:500]}")
        payload = response.json()
        if not payload.get("success"):
            self._trace(tool, operation, body["params"], started, error=payload.get("error"))
            raise Refused(payload.get("error") or "Salesforce declined the request.")
        result = with_local_times(payload.get("result"))
        self._trace(tool, operation, body["params"], started, result=result)
        return result

    async def _post(self, body):
        return await self._client.post(
            self._instance + ENDPOINT, json=body,
            headers={"Authorization": f"Bearer {self._token}", "Content-Type": "application/json"},
        )

    def _trace(self, tool, operation, params, started, result=None, error=None):
        entry = {
            "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "tool": tool,
            "operation": operation,
            "params": {k: (f"<{len(v)} chars>" if k == "base64Data" else v) for k, v in params.items()},
            "ms": round((time.monotonic() - started) * 1000),
            "success": error is None,
        }
        if error is not None:
            entry["error"] = error
        else:
            text = json.dumps(result, default=str)
            entry["result"] = result if len(text) <= TRACE_LIMIT else text[:TRACE_LIMIT] + "..."
        self.trace_path.parent.mkdir(parents=True, exist_ok=True)
        with self.trace_path.open("a") as fh:
            fh.write(json.dumps(entry, default=str) + "\n")


def from_environment() -> Salesforce:
    trace = os.environ.get("VERDANT_TRACE") or str(Path.home() / ".verdant-field-assistant" / "trace.jsonl")
    return Salesforce(os.environ.get("VERDANT_ORG", "verdant"), Path(trace).expanduser())
