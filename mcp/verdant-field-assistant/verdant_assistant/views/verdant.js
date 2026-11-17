// Shared by every Verdant card: the MCP Apps connection and small formatting helpers.
// A card registers its handlers on Verdant.app, then calls Verdant.connect().
const { App } = window.McpApps;
const app = new App({ name: "Verdant Field Assistant", version: "1.0.0" }, {}, { autoResize: true });

function textOf(result) {
  return (result?.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
}

function parse(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = textOf(result);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

window.Verdant = {
  app,
  parse,
  connect: () => app.connect(),
  async call(name, args) {
    const result = await app.callServerTool({ name, arguments: args });
    if (result.isError) throw new Error(textOf(result).replace(/^Error executing tool \w+: /, ""));
    return parse(result);
  },
  async say(text) {
    try {
      await app.sendMessage({ role: "user", content: [{ type: "text", text }] });
    } catch (e) {
      console.warn("sendMessage failed", e);
    }
  },
  async tellModel(text) {
    try {
      await app.updateModelContext({ content: [{ type: "text", text }] });
    } catch (e) {
      console.warn("updateModelContext failed", e);
    }
  },
  money(value) {
    const n = Number(value || 0);
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 });
  },
  esc(value) {
    return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  },
  time(local) {
    // "Wed Nov 18, 9:00 AM Central" -> "9:00 AM"
    const match = /(\d{1,2}:\d{2} [AP]M)/.exec(local || "");
    return match ? match[1] : local || "";
  },
  error(element, e) {
    element.innerHTML = `<div class="error">${window.Verdant.esc(e.message || e)}</div>`;
  },
};
