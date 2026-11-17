// Stands in for the MCP Apps client when a card opens as a browser page (chat apps that can't show
// cards). Card actions go to the Verdant server's local page server; messages for Claude show in a
// banner for the presenter to paste back into the chat.
const ARGS = window.VERDANT_ARGS || {};
const TOKEN = window.VERDANT_TOKEN;
const RESULT = window.VERDANT_RESULT;

function banner(text, ask) {
  let box = document.getElementById("verdant-banner");
  if (!box) {
    box = document.createElement("div");
    box.id = "verdant-banner";
    box.className = "banner";
    document.body.appendChild(box);
  }
  box.innerHTML = "";
  const message = document.createElement("div");
  message.className = "banner-text";
  message.innerHTML = ask
    ? `<b>✓ Saved in Salesforce.</b> Back in Claude, say:<div class="quote"></div>`
    : `<b>✓ Saved in Salesforce.</b> <span></span>`;
  message.querySelector(ask ? ".quote" : "span").textContent = text;
  box.appendChild(message);
  if (ask) {
    const copy = document.createElement("button");
    copy.textContent = "Copy";
    copy.onclick = async () => {
      await navigator.clipboard.writeText(text);
      copy.textContent = "Copied";
    };
    box.appendChild(copy);
  }
}

class App {
  async connect() {
    document.body.classList.add("browser");
    this.ontoolinput?.({ arguments: ARGS });
    this.ontoolresult?.(RESULT ? { structuredContent: RESULT, content: [] } : { content: [] });
  }

  async callServerTool({ name, arguments: args }) {
    const response = await fetch(`/api/${name}?t=${encodeURIComponent(TOKEN)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(args || {}),
    });
    const body = await response.json().catch(() => ({ error: response.statusText }));
    return response.ok
      ? { structuredContent: body, content: [{ type: "text", text: JSON.stringify(body) }] }
      : { isError: true, content: [{ type: "text", text: body.error || "Something went wrong." }] };
  }

  async sendMessage({ content }) {
    banner(content.map((block) => block.text).join(" "), true);
  }

  async updateModelContext({ content }) {
    banner(content.map((block) => block.text).join(" "), false);
  }

  async downloadFile({ contents }) {
    const { uri, mimeType, blob } = contents[0].resource;
    const link = document.createElement("a");
    link.href = `data:${mimeType};base64,${blob}`;
    link.download = uri.split("/").pop();
    link.click();
  }
}

window.McpApps = { App };
