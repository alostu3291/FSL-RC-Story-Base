# Verdant Field Assistant (MCP server)

> **Presenting?** Start at [DEMO_SCRIPT.md](DEMO_SCRIPT.md): what to type, and `reset-demo.command` to reset before each run.

Runs the Verdant pest control demo from an LLM, with no Salesforce or Field Service screens. The
customer calls, a free inspection is booked, the technician inspects and quotes, the customer signs,
the order books the first treatment, and on the treatment day the technician records the work and
adds upgrades or add-ons. Assets, guarantees, maintenance visits and invoices follow in Salesforce
in the background.

```
Claude Desktop ──stdio──▶ verdant-field-assistant (this server)
                              │  sf org display --json (auth), JSONL trace
                              ▼
                 POST /services/apexrest/verdant/assistant   (RLM_RTK_AssistantApi)
                              ▼
       Field Service / Revenue Cloud Apex the mobile flows use (FieldVisit, Inspection,
       FieldQuote, FieldAddOn, PlanChange, AI, BillExplainer, SignAndPay)
```

The LLM owns the conversation; Salesforce owns the rules. Prices, coverage, slots and billing are
always read from Salesforce, and the tools that commit a customer (signing, add-ons, plan changes)
need the customer's name or words as the approval.

## Prerequisites

- The org has the pest demo (`prepare_pest`) and the facade:
  `cci task run deploy_post_pest_mcp --org <org>` and the `RLM_RTK_Assistant` permission set
  (`prepare_pest` does both with `pest_mcp: true` and `docgen: true`).
- The `sf` CLI is logged in to the org (`sf org login web --alias verdant`).
- [uv](https://docs.astral.sh/uv/) and Python 3.10+.

## Run it in Claude Desktop

1. `cd mcp/verdant-field-assistant && uv sync`
2. Check it reaches the org: `uv run python smoke_test.py` (lists the tools and today's schedule).
3. Copy the `verdant-field-assistant` entry from `claude_desktop_config.example.json` into the
   `mcpServers` section of Claude's config, with this folder's absolute path and your sf alias in
   `VERDANT_ORG`, then quit (⌘Q) and reopen Claude. The config is
   `~/Library/Application Support/Claude/claude_desktop_config.json`, or
   `~/Library/Application Support/Claude-3p/claude_desktop_config.json` when Claude signs in through
   a company gateway (the account name shows "Gateway").
4. Create a Claude Project (for example "Verdant Field Assistant") and paste
   `verdant_assistant_prompt.md` into its instructions, or pick the `verdant_field_assistant`
   prompt from the server's prompt list at the start of a chat.

| Variable | Default | Meaning |
|----------|---------|---------|
| `VERDANT_ORG` | `verdant` | sf CLI alias or username |
| `VERDANT_TRACE` | `~/.verdant-field-assistant/trace.jsonl` | Execution trace: one line per Salesforce call, with timing |
| `VERDANT_ADMIN_TOOLS` | unset | `1` exposes `reset_demo` (presenter only; keep it off in the audience's chat) |

## Run it hosted in Salesforce (no Mac server)

The same tools also run on Salesforce's hosted MCP server, so the demo works from the Salesforce
Demo Claude account with nothing running locally:

```
Claude (Salesforce Demo account) ──"SDO / IDO - HXL - Customizable" connector──▶ HXLXDO hosted MCP server
                                                                                      ▼
                         RLM_RTK_Mcp* invocable actions (one per tool) ──▶ RLM_RTK_McpTool ──▶ RLM_RTK_AssistantApi.run
```

1. Install the Headless 360 Surface Demo Connector QBrix in the org (it creates `HXLXDO`).
2. `cci task run deploy_post_pest_mcp_hosted --org verdant` (needs `deploy_post_pest_mcp`). It adds
   the 29 Verdant tools to `HXLXDO` next to its four HXL tools. Re-run it after reinstalling the
   QBrix, which resets the server's tool list.
3. In the Demo Claude account, connect **SDO / IDO - HXL - Customizable** (Settings → Connectors)
   and log in to the org.
4. Create a Project and paste `hosted_project_instructions.md` into its instructions.

Differences from the Mac server: no photo upload and no `reset_demo` tool (reset with
`reset-demo.command`), and `generate_proposal` and `place_order` return right away while Claude
checks `get_proposal_status` and `get_order_status`. Each tool returns `success`, `error` and
`result` (JSON with the same `...Local` Central-time labels). To change a tool, edit its
`RLM_RTK_Mcp*` class and its entry in `unpackaged/post_pest_mcp_hosted/mcpServerDefinitions/HXLXDO.mcpServerDefinition`
(API 67.0; deploy with the CCI task or the latest `sf` CLI).

## Before and between demos

```bash
uv run python rehearse.py --reset      # archive the last Sarah Mitchell, then play the whole storyline
cci task run reset_verdant_llm_demo --org verdant   # archive Sarah and re-seed the backup customers
tail -f ~/.verdant-field-assistant/trace.jsonl       # watch the calls live on a second screen
```

`rehearse.py` makes the same tool calls an LLM would, as Sarah Mitchell, and stops at the first
refusal. Leave the org reset (not rehearsed) before the audience arrives. The run-of-show is in
[docs/guides/pest-control-demo.md](../../docs/guides/pest-control-demo.md#llm-demo-verdant-field-assistant).

## Tools

| Storyline step | Tools |
|----------------|-------|
| The customer calls | `book_inspection_for_caller`, `report_reservice`, `find_customer` |
| Plan the day | `get_my_schedule` (any day), `get_visit_brief`, `get_customer_summary`, `get_visit_status` |
| Inspect | `start_visit`, `record_finding`, `attach_finding_photo`, `get_inspection` |
| Quote | `get_plan_pricing`, `create_quote`, `get_quote`, `generate_proposal`, `get_proposal_status` |
| Sign and order | `record_customer_acceptance`, `place_order`, `get_order_status` |
| Schedule the follow-up | `find_treatment_slots`, `book_treatment` |
| Treatment visit | `get_treatment_checklist`, `record_treatment`, `get_add_on_options`, `add_add_ons`, `get_plan_options`, `change_plan`, `complete_visit`, `send_visit_summary` |
| Billing (read-only) | `explain_bill` |
| Presenter | `reset_demo` (only with `VERDANT_ADMIN_TOOLS=1`) |

Visit tools take a work order or service appointment Id. Every UTC timestamp in a result gets a
`<field>Local` label in Central time (the Bloomingdale territory's clock).

## Notes

- **Changing days.** Dates are real. "It's Thursday now" means `get_my_schedule` for Thursday;
  starting a visit booked for a later day works, so the story can jump ahead without a fake clock.
- **Slow steps.** `generate_proposal` waits up to 90 seconds and `place_order` up to 2 minutes for
  fulfillment to create the first treatment; the matching `get_..._status` tools pick up from there.
- **Billing.** Invoices come from the billing schedules in Salesforce's background invoice run, so
  a brand-new customer has no bill during the demo. Use Sam Patel from the backup cast for
  `explain_bill`.
- **Email.** Trial orgs send 15 single emails a day; each `send_visit_summary` uses one.
- **Photos.** `attach_finding_photo` takes a file path (resized to 1600 px) or base64.
