(() => {
  "use strict";

  const feed = document.querySelector("#feed-table");
  if (!feed) return;

  const state = document.querySelector("[data-stream-state]");
  let versionTimer;
  let refreshPending = false;

  const setState = (online) => {
    if (!state) return;
    state.classList.toggle("is-stale", !online);
    const strong = state.querySelector("strong");
    const detail = state.querySelector("span");
    if (strong) strong.textContent = online ? "AO VIVO" : "RECONECTANDO";
    if (detail && detail.lastChild) detail.lastChild.textContent = online ? " mercado sincronizado" : " verificando atualizações";
  };

  const refreshFeed = () => {
    if (refreshPending) return;
    refreshPending = true;
    window.htmx?.trigger(document.body, "gts:refresh");
    window.setTimeout(() => { refreshPending = false; }, 900);
  };

  const checkVersion = async () => {
    if (document.hidden) return;
    try {
      const response = await fetch("/feed/version", {
        cache: "no-store",
        credentials: "same-origin",
        headers: { "Accept": "application/json" },
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const currentFeed = document.querySelector("#feed-table");
      const currentId = Number(currentFeed?.dataset.latestId || 0);
      if (Number(data.id) > currentId) refreshFeed();
      setState(true);
    } catch (_) {
      setState(false);
    }
  };

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) checkVersion();
  });
  versionTimer = window.setInterval(checkVersion, 1000);
  window.addEventListener("pagehide", () => {
    window.clearInterval(versionTimer);
  });
  checkVersion();
})();
