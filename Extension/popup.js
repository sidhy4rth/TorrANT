const HOST = "com.sidhy4rth.torrant";
const $ = (id) => document.getElementById(id);

async function render() {
  const s = await chrome.storage.local.get({ enabled: true, caught: 0, lastCaught: "" });
  $("enabled").checked = s.enabled;
  $("mode").textContent = s.enabled ? "Every Brave download goes to TorrANT" : "Off: Brave downloads things itself";
  $("caught").textContent = s.caught;
  $("last").textContent = s.lastCaught || "—";
  $("last").title = s.lastCaught || "";
}

async function checkColony() {
  const box = $("status"), text = $("statusText");
  try {
    const reply = await chrome.runtime.sendNativeMessage(HOST, { type: "ping" });
    if (reply && reply.ok) {
      box.className = "row status up";
      text.textContent = "TorrANT is running. Ants are ready.";
    } else {
      box.className = "row status down";
      text.textContent = "TorrANT is closed. Brave keeps downloads for now.";
    }
  } catch {
    box.className = "row status down";
    text.textContent = "Open TorrANT once to connect it to Brave.";
  }
}

$("enabled").addEventListener("change", async (e) => {
  await chrome.storage.local.set({ enabled: e.target.checked });
  render();
});

render();
checkColony();
