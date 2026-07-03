(() => {
  "use strict";

  const feed = document.querySelector("#feed-table");
  if (!feed || !window.EventSource) return;

  const state = document.querySelector("[data-stream-state]");
  let source;
  let reconnectTimer;

  const setState = (online) => {
    if (!state) return;
    state.classList.toggle("is-stale", !online);
    const strong = state.querySelector("strong");
    const detail = state.querySelector("span");
    if (strong) strong.textContent = online ? "AO VIVO" : "RECONECTANDO";
    if (detail && detail.lastChild) detail.lastChild.textContent = online ? " log sincronizada" : " aguardando conexão";
  };

  const connect = () => {
    const currentFeed = document.querySelector("#feed-table");
    const lastId = currentFeed?.dataset.latestId || "0";
    source = new EventSource(`/stream?last_id=${encodeURIComponent(lastId)}`);
    source.addEventListener("open", () => setState(true));
    source.addEventListener("listing", () => {
      setState(true);
      window.htmx?.trigger(document.body, "gts:refresh");
    });
    source.addEventListener("error", () => {
      setState(false);
      source.close();
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, 2500);
    });
  };

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && (!source || source.readyState === EventSource.CLOSED)) connect();
  });
  connect();
})();
