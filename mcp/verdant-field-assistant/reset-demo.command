#!/bin/zsh
# Double-click in Finder (or run ./reset-demo.command) before each Verdant LLM demo.
# Archives the last Sarah Mitchell and re-seeds the backup customers in the verdant org.
cd "$(dirname "$0")/../.." || exit 1
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cci task run reset_verdant_llm_demo --org "${VERDANT_CCI_ORG:-verdant}"
echo
echo "Done. Start a NEW chat in the verdant-field-assistant Claude Project."
read -k1 "?Press any key to close..."
