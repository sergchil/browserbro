// BrowserBro for Chrome (prototype).
// Chrome is the default browser. When a link arrives from another app, Chrome opens it in the
// last-used profile. This worker sees that tab, asks the BrowserBro app where the link belongs,
// and closes the tab when BrowserBro opens the link in another profile.

const API = 'http://127.0.0.1:41417';   // BrowserBro app, see Sources/BrowserBro/Bridge.swift

const first = new Map();                // tabId → first URL of the navigation (before redirects)
const asked = new Set();                // tabs already reported to BrowserBro since this worker started

// Makes Chrome start this worker together with the profile, not at the first event it hears.
chrome.runtime.onStartup.addListener(() => {});

// Loaded from BrowserBro's setup page: that page names this profile, so BrowserBro learns
// which profile this install lives in. Then the setup tab closes.
chrome.runtime.onInstalled.addListener(async () => {
  for (const tab of await chrome.tabs.query({ url: `${API}/setup*` })) {
    const profile = new URL(tab.url).searchParams.get('profile');
    if (!profile) continue;
    try {
      await post('/pair', { profile });
      setTimeout(() => chrome.tabs.remove(tab.id).catch(() => {}), 2500);
    } catch (e) {
      // BrowserBro is not running: it learns the profile from the first routed link instead.
    }
  }
});

async function installId() {
  const { install } = await chrome.storage.local.get('install');
  if (install) return install;
  const fresh = crypto.randomUUID();
  await chrome.storage.local.set({ install: fresh });
  return fresh;
}

async function post(path, body) {
  const response = await fetch(`${API}${path}`, {
    method: 'POST',
    body: JSON.stringify({ ...body, install: await installId() }),
  });
  return response.json();
}

// BrowserBro answers "keep" (the tab is in the right place) or "close" (it opens the link elsewhere).
async function ask(tabId, report) {
  asked.add(tabId);
  try {
    const { action } = await post('/route', report);
    if (action === 'close') await chrome.tabs.remove(tabId);
  } catch (e) {
    // BrowserBro is not running, or the tab is gone: leave things as Chrome did them.
  }
}

chrome.webNavigation.onBeforeNavigate.addListener(d => {
  if (d.frameId === 0) first.set(d.tabId, d.url);
});

chrome.tabs.onRemoved.addListener(tabId => {
  first.delete(tabId);
  asked.delete(tabId);
});

// Chrome is running: a link from another app shows up as a "start_page" navigation.
chrome.webNavigation.onCommitted.addListener(d => {
  if (d.frameId !== 0) return;
  const url = first.get(d.tabId) || d.url;
  first.delete(d.tabId);
  if (d.transitionType !== 'start_page' || !/^https?:/i.test(url)) return;
  ask(d.tabId, { url, committed: d.url, transition: d.transitionType });
});

// Chrome was closed: the link that starts Chrome can load before this worker runs, and then no
// event arrives for it. Report every tab with a fresh history visit; BrowserBro knows when Chrome
// started and keeps only a tab that this start opened.
async function scanTabs() {
  for (const tab of await chrome.tabs.query({})) {
    if (asked.has(tab.id) || !/^https?:/i.test(tab.url || '')) continue;
    const visits = await chrome.history.getVisits({ url: tab.url });
    const last = visits[visits.length - 1];
    if (!last || last.transition === 'reload' || Date.now() - last.visitTime > 60000) continue;
    ask(tab.id, { url: tab.url, committed: tab.url, cold: true, visitTime: last.visitTime, transition: last.transition });
  }
}

(async () => {
  // Once per Chrome start, not every time the worker wakes up.
  const { scanned } = await chrome.storage.session.get('scanned');
  if (scanned) return;
  await chrome.storage.session.set({ scanned: true });
  post('/hello', { version: chrome.runtime.getManifest().version }).catch(() => {});
  for (const delay of [700, 2500, 6000]) setTimeout(scanTabs, delay);
})();
