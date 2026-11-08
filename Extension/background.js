// TorrANT Catcher: every download Brave starts is handed to TorrANT,
// with the site's cookies so signed-in downloads keep working.
// If TorrANT is closed or says no, Brave keeps the download as usual.

const HOST = "com.sidhy4rth.torrant";
const MIN_BYTES = 1024 * 1024;          // smaller files stay in Brave
const REPLY_TIMEOUT_MS = 15000;
const RED = "#D7261F";

async function settings() {
  const s = await chrome.storage.local.get({ enabled: true, caught: 0 });
  return s;
}

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error("TorrANT didn't answer")), ms)),
  ]);
}

function baseName(path) {
  return (path || "").split(/[\\/]/).pop();
}

function isTorrent(item) {
  const name = (baseName(item.filename) || item.finalUrl || item.url || "").toLowerCase();
  return item.mime === "application/x-bittorrent" || /\.torrent($|\?)/.test(name);
}

/** Why this download should stay in Brave, or null to hand it over. */
function reasonToSkip(item, enabled) {
  if (!enabled) return "off";
  if (item.incognito) return "private window";
  if (item.byExtensionId) return "started by an extension";
  const url = item.finalUrl || item.url || "";
  if (!/^(https?|ftp):/i.test(url)) return "not a web link";
  if (isTorrent(item)) return null;     // tiny, but always a swarm for the ants
  const size = item.totalBytes > 0 ? item.totalBytes : item.fileSize;
  if (!(size > 0)) return "unknown size";
  if (size < MIN_BYTES) return "under 1 MB";
  return null;
}

async function cookieHeader(url) {
  try {
    const jar = await chrome.cookies.getAll({ url });
    return jar.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

async function flash(text) {
  await chrome.action.setBadgeBackgroundColor({ color: RED });
  await chrome.action.setBadgeText({ text });
  setTimeout(refreshBadge, 2500);
}

async function refreshBadge() {
  const { enabled } = await settings();
  await chrome.action.setBadgeBackgroundColor({ color: "#3A3A3A" });
  await chrome.action.setBadgeText({ text: enabled ? "" : "OFF" });
}

async function handOver(item) {
  const { enabled, caught } = await settings();
  const skip = reasonToSkip(item, enabled);
  if (skip) return false;

  const url = item.finalUrl || item.url;
  const msg = {
    type: "catch",
    url,
    referrer: item.referrer || "",
    userAgent: navigator.userAgent,
    cookies: await cookieHeader(url),
    filename: baseName(item.filename),
    size: item.totalBytes > 0 ? item.totalBytes : 0,
  };

  let reply;
  try {
    reply = await withTimeout(chrome.runtime.sendNativeMessage(HOST, msg), REPLY_TIMEOUT_MS);
  } catch (e) {
    await chrome.storage.local.set({ lastProblem: String(e && e.message ? e.message : e) });
    return false;
  }
  if (!reply || !reply.ok) {
    await chrome.storage.local.set({ lastProblem: (reply && reply.reason) || "TorrANT said no" });
    return false;
  }

  try { await chrome.downloads.cancel(item.id); } catch {}
  try { await chrome.downloads.erase({ id: item.id }); } catch {}
  await chrome.storage.local.set({
    caught: caught + 1,
    lastCaught: msg.filename || new URL(url).pathname.split("/").pop() || url,
    lastProblem: "",
  });
  flash("ANT");
  return true;
}

// Fires once Brave knows the file's name and size, before anything is
// saved to its final place. Returning true lets us decide asynchronously.
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  handOver(item)
    .catch(() => false)
    .then((caught) => {
      if (!caught) {
        try { suggest(); } catch {}
      }
    });
  return true;
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.enabled) refreshBadge();
});
chrome.runtime.onInstalled.addListener(refreshBadge);
chrome.runtime.onStartup.addListener(refreshBadge);
