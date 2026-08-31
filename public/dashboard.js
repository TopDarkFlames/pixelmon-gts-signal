(() => {
  "use strict";

  const INTRO_SEEN = "gts-site-intro-seen-v1";
  const intro = document.querySelector("[data-site-intro]");
  const introForce = new URLSearchParams(window.location.search).get("intro") === "1";
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  document.querySelectorAll("[data-password-toggle]").forEach((button) => {
    const input = button.closest(".password-input")?.querySelector("[data-password-input]");
    if (!input) return;
    button.addEventListener("click", () => {
      const revealing = input.type === "password";
      input.type = revealing ? "text" : "password";
      button.textContent = revealing ? "Ocultar" : "Mostrar";
      button.setAttribute("aria-label", revealing ? "Ocultar senha" : "Mostrar senha");
      button.setAttribute("aria-pressed", String(revealing));
      input.focus();
    });
  });

  const closeIntro = () => {
    if (!intro || intro.dataset.closing === "true") return;
    intro.dataset.closing = "true";
    try {
      window.sessionStorage.setItem(INTRO_SEEN, "1");
    } catch (_) {
      // Navegadores privados podem bloquear sessionStorage.
    }
    intro.classList.add("is-done");
    document.body.classList.remove("intro-active");
    window.setTimeout(() => intro.remove(), 650);
  };

  if (intro) {
    let alreadySeen = false;
    try {
      alreadySeen = window.sessionStorage.getItem(INTRO_SEEN) === "1";
    } catch (_) {
      alreadySeen = false;
    }

    if (!introForce && (alreadySeen || reducedMotion)) {
      intro.remove();
    } else {
      document.body.classList.add("intro-active");
      intro.querySelector("[data-intro-skip]")?.addEventListener("click", closeIntro);
      intro.querySelectorAll("[data-intro-line]").forEach((line, index) => {
        window.setTimeout(() => line.classList.add("is-active"), 280 + index * 430);
      });
      window.setTimeout(closeIntro, 3900);
    }
  }

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

  document.addEventListener("click", async (event) => {
    const button = event.target.closest("[data-copy-value]");
    if (!button) return;
    const original = button.textContent;
    try {
      await navigator.clipboard.writeText(button.dataset.copyValue || "");
      button.textContent = "Copiado";
      window.setTimeout(() => { button.textContent = original; }, 1200);
    } catch (_) {
      button.textContent = "Falhou";
      window.setTimeout(() => { button.textContent = original; }, 1200);
    }
  });

  const MERCHANT_SOUND_ENABLED = "merchant-sound-enabled";
  const MERCHANT_CURSOR = "merchant-version-cursor";
  const merchantSoundButton = document.querySelector("[data-merchant-sound-toggle]");
  const merchantSoundStatus = document.querySelector("[data-merchant-sound-status]");
  let merchantTimer;
  let merchantAudioContext;

  const merchantSoundEnabled = () => localStorage.getItem(MERCHANT_SOUND_ENABLED) === "1";

  const updateMerchantSoundControl = () => {
    if (!merchantSoundButton || !merchantSoundStatus) return;
    const enabled = merchantSoundEnabled();
    merchantSoundButton.textContent = enabled ? "Desativar som" : "Ativar som";
    merchantSoundStatus.textContent = enabled ? "Som armado neste navegador" : "Som desativado neste navegador";
  };

  const playMerchantSound = async () => {
    if (!merchantSoundEnabled()) return;
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) return;
    merchantAudioContext ||= new AudioContext();
    if (merchantAudioContext.state === "suspended") await merchantAudioContext.resume();
    const start = merchantAudioContext.currentTime;
    [880, 1175, 1568].forEach((frequency, index) => {
      const oscillator = merchantAudioContext.createOscillator();
      const gain = merchantAudioContext.createGain();
      oscillator.type = "sine";
      oscillator.frequency.value = frequency;
      oscillator.connect(gain);
      gain.connect(merchantAudioContext.destination);
      gain.gain.setValueAtTime(0.0001, start + index * 0.16);
      gain.gain.exponentialRampToValueAtTime(0.18, start + index * 0.16 + 0.03);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + index * 0.16 + 0.13);
      oscillator.start(start + index * 0.16);
      oscillator.stop(start + index * 0.16 + 0.15);
    });
  };

  const currentMerchantVersion = async () => {
    const response = await fetch("/merchant/version", { cache: "no-store", credentials: "same-origin" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  };

  const showMerchantToast = (spawn) => {
    const existing = document.querySelector(".site-toast");
    existing?.remove();
    const toast = document.createElement("aside");
    toast.className = "site-toast";
    const label = document.createElement("span");
    const location = document.createElement("strong");
    const coordinates = document.createElement("small");
    label.textContent = "Mercador Viajante";
    location.textContent = spawn.location || `/warp ${spawn.world || "lohr"}`;
    coordinates.textContent = spawn.coordinate_text || "";
    toast.append(label, location, coordinates);
    document.body.appendChild(toast);
    requestAnimationFrame(() => toast.classList.add("is-visible"));
    window.setTimeout(() => {
      toast.classList.remove("is-visible");
      window.setTimeout(() => toast.remove(), 250);
    }, 9000);
  };

  const notifyMerchant = async (spawn) => {
    showMerchantToast(spawn);
    await playMerchantSound();
    window.htmx?.trigger(document.body, "merchant:refresh");
    if (notificationsSupported && notificationsEnabled() && Notification.permission === "granted") {
      const registration = await navigator.serviceWorker.ready;
      await registration.showNotification("Mercador Viajante", {
        body: `${spawn.location || `/warp ${spawn.world || "lohr"}`} · ${spawn.coordinate_text || ""}`,
        tag: `merchant-${spawn.id}`,
        data: { url: "/merchant" },
      });
    }
  };

  const pollMerchant = async () => {
    if (document.body.dataset.authenticated !== "true") return;
    try {
      const spawn = await currentMerchantVersion();
      const latestId = Number(spawn.id || 0);
      const cursorValue = localStorage.getItem(MERCHANT_CURSOR);
      if (cursorValue === null) {
        localStorage.setItem(MERCHANT_CURSOR, String(latestId));
        return;
      }
      const cursor = Number(cursorValue || 0);
      if (latestId > cursor) {
        localStorage.setItem(MERCHANT_CURSOR, String(latestId));
        await notifyMerchant(spawn);
      }
    } catch (_) {
      // O próximo polling retoma do mesmo cursor.
    }
  };

  if (merchantSoundButton) {
    merchantSoundButton.addEventListener("click", async () => {
      if (merchantSoundEnabled()) localStorage.removeItem(MERCHANT_SOUND_ENABLED);
      else {
        localStorage.setItem(MERCHANT_SOUND_ENABLED, "1");
        await playMerchantSound();
      }
      updateMerchantSoundControl();
    });
  }
  updateMerchantSoundControl();
  if (document.body.dataset.authenticated === "true") {
    merchantTimer = window.setInterval(pollMerchant, 1500);
    pollMerchant();
  }
  window.addEventListener("pagehide", () => {
    window.clearInterval(notificationTimer);
    window.clearInterval(merchantTimer);
  });

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
    window.clearInterval(merchantTimer);
  });
  checkVersion();
})();
