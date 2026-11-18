# Verdant LLM Demo: Presenter Script

Everything for running the demo lives in this folder:

| File | What it's for |
|------|---------------|
| `DEMO_SCRIPT.md` | This page: what to type into Claude, step by step |
| `reset-demo.command` | Reset before each demo (double-click in Finder) |
| `verdant_assistant_prompt.md` | Paste into the Claude Project's instructions (one time) |
| `hosted_project_instructions.md` | The same, for the hosted version in the Salesforce Demo Claude account |
| `claude_desktop_config.example.json` | Connects Claude to Salesforce (one time; see [README](README.md#run-it-in-claude-desktop)) |

## Before each demo

1. Double-click `reset-demo.command` (or run `cci task run reset_verdant_llm_demo --org verdant` from the repo root). About 20 seconds.
2. In Claude, open the **verdant-field-assistant** Project and start a **new chat**.
3. Check **+ → Connectors → verdant-field-assistant** is on.
4. Optional second screen: `tail -f ~/.verdant-field-assistant/trace.jsonl` shows each Salesforce call live.

The first time Claude uses a tool, choose **Allow always**.

**Hosted instead (Salesforce Demo Claude account, no Mac server):** reset the same way, open the
Project that has `hosted_project_instructions.md`, start a new chat and check **SDO / IDO - HXL -
Customizable** is connected. The script below is the same, except that the proposal and the first
treatment visit take up to a minute or two while Claude checks on them itself. If Claude reaches
for another connector, say "use the SDO / IDO - HXL connector".

## What to type

**1. The customer calls**

```
Office here. Sarah Mitchell is on the phone, 218 Maple Ridge Dr, (630) 555-0101. She has ants in the kitchen, something buzzing by the back porch, and noises in the attic. Can we get someone out tomorrow morning?
```

Claude creates Sarah and books a free inspection dispatched to you.

**2. Plan the day**

```
Tech here, it's tomorrow morning. What's my day?
```
```
Brief me on Sarah.
```

**3. Inspect**

```
I'm at Sarah's.
```
```
Ant trail along the sink, moderate. Paper wasp nest under the back porch eaves. Fresh mouse droppings by the attic hatch.
```

Claude records one finding per item and recommends a plan.

**4. Quote**

```
Quote it. The house is under 2,000 square feet.
```

Claude reads back the monthly price, the one-time Initial Service and why, and generates the proposal.

**5. Sign and order**

```
Sarah says yes, go ahead. Card ending 4242.
```

Claude records her signature and places the order; fulfillment creates the first treatment visit.

**6. Schedule the follow-up**

```
When can we come back to treat?
```

Pick one of the times it offers (for example "The first one works."). Claude books it and closes the inspection visit.

**7. Jump to the treatment day**

```
It's the treatment day now. What's my day?
```
```
Starting Sarah's treatment.
```

**8. Treat and find an add-on**

```
Kitchen treated, baited along the sink. Attic droppings cleaned and traps set. The wasp nest is big, she wants it gone.
```

Claude records each treatment and offers wasp nest removal with its price. Approve it:

```
Yes, Sarah approves the nest removal.
```

**9. Upgrade the plan**

```
She sees wasps every year. Is there a plan that covers that?
```

Claude shows Home Protection Plus and the new monthly price. Approve it:

```
She wants the upgrade.
```

**10. Finish**

```
All done.
```

Claude completes the visit (guarantees and the recurring visit schedule start) and emails Sarah a summary.

**11. Show the result and billing**

```
What does Sarah have now?
```
```
Why is Sam Patel's bill $366?
```

Sarah's own invoice comes from the background invoice run, so use Sam Patel for the billing question.

## If something goes off script

- Claude explains any refusal from Salesforce in plain words; answer it or rephrase.
- A slow step (proposal, order) can take a minute or two; Claude waits.
- Backup customers are on tomorrow's schedule: Aisha Brooks (first treatment, 11:00), Casey Morgan (covered re-service, 15:00), Sam Patel (not covered re-service, 16:00). Say "Let's go to Aisha's treatment instead."
- Trial orgs send 15 emails a day; each visit summary uses one.
