(() => {
  "use strict";

  const NOTIFICATION_ENABLED = "gts-browser-notifications";
  const NOTIFICATION_CURSOR = "gts-notification-cursor";
  const notificationButton = document.querySelector("[data-notification-toggle]");
  const notificationStatus = document.querySelector("[data-notification-status]");
  let notificationTimer;

  const notificationsSupported = "Notification" in window && "serviceWorker" in navigator;
  const notificationsEnabled = () => localStorage.getItem(NOTIFICATION_ENABLED) === "1";

  const updateNotificationControl = () => {
    if (!notificationButton || !notificationStatus) return;
    if (!notificationsSupported) {
      notificationStatus.textContent = "Este navegador não oferece suporte";
      notificationButton.disabled = true;
      return;
    }
    const enabled = notificationsEnabled() && Notification.permission === "granted";
    notificationStatus.textContent = enabled ? "Notificações ativadas" : (Notification.permission === "denied" ? "Permissão bloqueada no navegador" : "Notificações desativadas");
    notificationButton.textContent = enabled ? "Desativar" : "Ativar notificações";
  };

  const currentFeedVersion = async () => {
    const response = await fetch("/feed/version", { cache: "no-store", credentials: "same-origin" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return Number((await response.json()).id || 0);
  };

  const enableNotifications = async () => {
    if (!notificationsSupported) return;
    const permission = await Notification.requestPermission();
    if (permission !== "granted") {
      localStorage.removeItem(NOTIFICATION_ENABLED);
      updateNotificationControl();
      return;
    }
    await navigator.serviceWorker.register("/sw.js");
    localStorage.setItem(NOTIFICATION_ENABLED, "1");
    localStorage.setItem(NOTIFICATION_CURSOR, String(await currentFeedVersion()));
    window.clearInterval(notificationTimer);
    notificationTimer = window.setInterval(pollNotifications, 3000);
    updateNotificationControl();
  };

  const disableNotifications = () => {
    localStorage.removeItem(NOTIFICATION_ENABLED);
    window.clearInterval(notificationTimer);
    updateNotificationControl();
  };

  const pollNotifications = async () => {
    if (!notificationsSupported || !notificationsEnabled() || Notification.permission !== "granted") return;
    try {
      const cursor = Number(localStorage.getItem(NOTIFICATION_CURSOR) || await currentFeedVersion());
      const response = await fetch(`/notifications/check?after=${encodeURIComponent(cursor)}`, { cache: "no-store", credentials: "same-origin" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const registration = await navigator.serviceWorker.ready;
      for (const listing of data.matches || []) {
        await registration.showNotification(`GTS: ${listing.item}`, {
          body: `${listing.price} · ${listing.seller}\n${listing.reasons.join(" · ")}`,
          tag: `gts-listing-${listing.id}`,
          data: { url: `/listing/${listing.id}` },
        });
      }
      localStorage.setItem(NOTIFICATION_CURSOR, String(data.cursor || cursor));
    } catch (_) {
      // A próxima verificação retoma do mesmo cursor.
    }
  };

  if (notificationButton) {
    notificationButton.addEventListener("click", () => {
      if (notificationsEnabled()) disableNotifications();
      else enableNotifications();
    });
  }
  updateNotificationControl();
  if (notificationsSupported && notificationsEnabled()) {
    navigator.serviceWorker.register("/sw.js");
    notificationTimer = window.setInterval(pollNotifications, 3000);
    pollNotifications();
  }

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
      const latestId = await currentFeedVersion();
      const currentFeed = document.querySelector("#feed-table");
      const currentId = Number(currentFeed?.dataset.latestId || 0);
      if (latestId > currentId) refreshFeed();
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
    window.clearInterval(notificationTimer);
  });
  checkVersion();
})();
