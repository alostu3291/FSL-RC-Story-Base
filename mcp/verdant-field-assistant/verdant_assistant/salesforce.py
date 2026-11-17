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
DATA_API = "/services/data/v66.0"
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
        started = time.monotonic()
        body = {"operation": operation, "params": {k: v for k, v in params.items() if v is not None}}
        response = await self._request("POST", ENDPOINT, json=body)
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

    async def query(self, soql: str) -> list:
        response = await self._request("GET", f"{DATA_API}/query", params={"q": soql})
        self._raise_for(response)
        return response.json()["records"]

    async def download(self, tool: str, path: str) -> bytes:
        """A file's bytes, for example /sobjects/ContentVersion/<id>/VersionData."""
        started = time.monotonic()
        response = await self._request("GET", DATA_API + path)
        self._raise_for(response)
        self._trace(tool, "download", {"path": path}, started, result=f"<{len(response.content)} bytes>")
        return response.content

    async def create(self, tool: str, sobject: str, fields: dict) -> str:
        started = time.monotonic()
        response = await self._request("POST", f"{DATA_API}/sobjects/{sobject}", json=fields)
        self._raise_for(response)
        record_id = response.json()["id"]
        summary = {k: (f"<{len(v)} chars>" if k == "VersionData" else v) for k, v in fields.items()}
        self._trace(tool, f"create {sobject}", summary, started, result={"id": record_id})
        return record_id

    async def _request(self, method, path, **kwargs):
        if self._token is None:
            await self._authenticate()
        response = await self._send(method, path, **kwargs)
        if response.status_code == 401:
            await self._authenticate()
            response = await self._send(method, path, **kwargs)
        return response

    async def _send(self, method, path, **kwargs):
        return await self._client.request(
            method, self._instance + path, headers={"Authorization": f"Bearer {self._token}"}, **kwargs,
        )

    @staticmethod
    def _raise_for(response):
        if response.status_code >= 300:
            raise Unavailable(f"Salesforce returned HTTP {response.status_code}: {response.text[:500]}")

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
