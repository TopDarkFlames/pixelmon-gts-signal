#!/usr/bin/env python3
"""Launcher desktop nativo do Pixelmon GTS (Tkinter, sem servidor web)."""

from __future__ import annotations

import subprocess
import threading
import time
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import messagebox

ROOT = Path(__file__).resolve().parent.parent
SERVICE = "pixelmon-gts.service"
BG, CARD, CARD2 = "#080b16", "#11172a", "#19233d"
WHITE, MUTED, PURPLE, BLUE = "#f4f7ff", "#8994b7", "#8d5cff", "#4b86ff"
GREEN, RED, AMBER = "#43e39b", "#ff647c", "#ffbd4a"


def systemctl(*args: str) -> tuple[int, str]:
    result = subprocess.run(
        ["systemctl", "--user", *args, SERVICE],
        cwd=ROOT, capture_output=True, text=True, timeout=15,
    )
    return result.returncode, (result.stdout + result.stderr).strip()


def get_status() -> dict[str, object]:
    active_code, active_output = systemctl("is-active")
    enabled_code, enabled_output = systemctl("is-enabled")
    site_file = ROOT / "runtime" / "site_url.txt"
    tunnel_file = ROOT / "runtime" / "tunnel_status.txt"
    url = site_file.read_text(encoding="utf-8").strip() if site_file.exists() else ""
    tunnel = "offline"
    if tunnel_file.exists():
        tunnel = tunnel_file.read_text(encoding="utf-8").strip().split("\t", 1)[0]
    return {
        "active": active_code == 0 and active_output == "active",
        "enabled": enabled_code == 0 and enabled_output == "enabled",
        "tunnel": tunnel,
        "url": url,
    }


def logs() -> str:
    sources = [("PAINEL", "painel-permanente.log"), ("BOT", "gts-bot-permanente.log"), ("TÚNEL", "cloudflare-contingencia.log")]
    blocks = []
    for name, filename in sources:
        path = ROOT / "runtime" / filename
        if path.exists():
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-9:]
            blocks.append(f"[{name}]\n" + "\n".join(lines))
    return "\n\n".join(blocks)[-8000:] or "Nenhuma atividade registrada ainda."


class Launcher(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Pixelmon GTS • Control Center")
        self.geometry("960x620")
        self.minsize(780, 520)
        self.configure(bg=BG)
        self.busy = False
        self.current_url = ""
        self.protocol("WM_DELETE_WINDOW", self.destroy)
        self.build()
        self.refresh()

    def text(self, parent: tk.Widget, value: str, size: int, color: str = WHITE, **kwargs: object) -> tk.Label:
        return tk.Label(parent, text=value, fg=color, bg=parent.cget("bg"), font=("DejaVu Sans", size), **kwargs)

    def card(self, parent: tk.Widget) -> tk.Frame:
        return tk.Frame(parent, bg=CARD, highlightbackground="#27304d", highlightthickness=1, bd=0)

    def build(self) -> None:
        root = tk.Frame(self, bg=BG)
        root.pack(fill="both", expand=True, padx=28, pady=24)
        header = tk.Frame(root, bg=BG)
        header.pack(fill="x", pady=(0, 20))
        tk.Label(header, text="⚡", fg=WHITE, bg=PURPLE, font=("DejaVu Sans", 24), width=2, height=1).pack(side="left", padx=(0, 13))
        title = tk.Frame(header, bg=BG)
        title.pack(side="left")
        self.text(title, "PERSONAL CONTROL CENTER", 9, MUTED).pack(anchor="w")
        self.text(title, "Pixelmon GTS", 27).pack(anchor="w")
        self.text(header, "LOCAL • MANUAL MODE", 9, MUTED).pack(side="right", pady=10)

        top = tk.Frame(root, bg=BG)
        top.pack(fill="x")
        top.grid_columnconfigure(0, weight=11)
        top.grid_columnconfigure(1, weight=9)
        hero = self.card(top)
        hero.grid(row=0, column=0, sticky="nsew", padx=(0, 10), pady=(0, 15))
        self.text(hero, "Seu servidor, sob seu comando.", 16, "#cbd4f4").pack(anchor="w", padx=23, pady=(21, 4))
        self.text(hero, "Ligue painel, bot, notificações e túnel público quando quiser.", 10, MUTED).pack(anchor="w", padx=23)
        state = tk.Frame(hero, bg=CARD)
        state.pack(fill="x", padx=23, pady=21)
        self.dot = self.text(state, "●", 28, AMBER)
        self.dot.pack(side="left", padx=(0, 11))
        state_info = tk.Frame(state, bg=CARD)
        state_info.pack(side="left")
        self.text(state_info, "ESTADO DO SISTEMA", 9, MUTED).pack(anchor="w")
        self.state = self.text(state_info, "CARREGANDO...", 24)
        self.state.pack(anchor="w")
        self.toggle = tk.Button(hero, text="VERIFICANDO...", command=self.toggle_service, state="disabled", fg=WHITE, bg=PURPLE, activebackground=BLUE, activeforeground=WHITE, relief="flat", bd=0, cursor="hand2", font=("DejaVu Sans", 12, "bold"), pady=12)
        self.toggle.pack(fill="x", padx=23, pady=(0, 22))

        monitor = self.card(top)
        monitor.grid(row=0, column=1, sticky="nsew", pady=(0, 15))
        self.text(monitor, "MONITORAMENTO", 10, MUTED).pack(anchor="w", padx=21, pady=(21, 13))
        self.service = self.status_row(monitor, "Serviço systemd")
        self.tunnel = self.status_row(monitor, "Túnel público")
        self.url = self.status_row(monitor, "URL ativa")
        self.boot = self.status_row(monitor, "Início automático")
        self.text(monitor, "Acesso local  127.0.0.1:8080", 10, "#9ca8c9").pack(anchor="w", padx=21, pady=(16, 5))
        self.open_button = tk.Button(monitor, text="ABRIR PAINEL WEB ↗", command=self.open_panel, fg="#dce5ff", bg=CARD2, activebackground="#2a3b65", activeforeground=WHITE, relief="flat", bd=0, cursor="hand2", font=("DejaVu Sans", 9, "bold"), pady=9)
        self.open_button.pack(fill="x", padx=21, pady=(4, 20))

        log_card = self.card(root)
        log_card.pack(fill="both", expand=True)
        heading = tk.Frame(log_card, bg=CARD)
        heading.pack(fill="x", padx=18, pady=(13, 7))
        self.text(heading, "ATIVIDADE RECENTE", 10, MUTED).pack(side="left")
        tk.Button(heading, text="ATUALIZAR", command=self.refresh_logs, fg="#aebcf0", bg=CARD, activebackground=CARD2, relief="flat", bd=0, cursor="hand2", font=("DejaVu Sans", 8, "bold")).pack(side="right")
        self.log_box = tk.Text(log_card, bg="#070a13", fg="#9aa8d1", relief="flat", bd=0, font=("DejaVu Sans Mono", 9), wrap="word", padx=14, pady=11)
        self.log_box.pack(fill="both", expand=True, padx=14, pady=(0, 14))
        self.log_box.configure(state="disabled")

    def status_row(self, parent: tk.Widget, name: str) -> tk.Label:
        row = tk.Frame(parent, bg=CARD)
        row.pack(fill="x", padx=21, pady=5)
        self.text(row, name, 10, MUTED).pack(side="left")
        value = self.text(row, "—", 10)
        value.pack(side="right")
        return value

    def apply_status(self, status: dict[str, object]) -> None:
        active = bool(status["active"])
        tunnel_online = status["tunnel"] == "online"
        self.dot.configure(fg=GREEN if active else RED)
        self.state.configure(text="ONLINE" if active else "OFFLINE")
        self.service.configure(text="ATIVO" if active else "PARADO", fg=GREEN if active else RED)
        self.tunnel.configure(text="ONLINE" if tunnel_online else "OFFLINE", fg=GREEN if tunnel_online else AMBER)
        self.current_url = str(status["url"] or "")
        self.url.configure(text="disponível" if self.current_url else "—", fg=GREEN if self.current_url else MUTED)
        self.boot.configure(text="não" if not status["enabled"] else "sim", fg=GREEN if not status["enabled"] else RED)
        self.toggle.configure(state="normal", text="DESLIGAR SISTEMA" if active else "LIGAR SISTEMA", bg=RED if active else PURPLE)
        self.open_button.configure(state="normal" if self.current_url else "disabled")

    def refresh(self) -> None:
        def work() -> None:
            try:
                status = get_status()
                self.after(0, lambda: self.apply_status(status))
            except Exception as exc:
                self.after(0, lambda: self.state.configure(text="ERRO"))
                print(f"Launcher: {exc}")
            self.after(5000, self.refresh)
        threading.Thread(target=work, daemon=True).start()
        self.refresh_logs()

    def refresh_logs(self) -> None:
        self.log_box.configure(state="normal")
        self.log_box.delete("1.0", "end")
        self.log_box.insert("1.0", logs())
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    def toggle_service(self) -> None:
        if self.busy:
            return
        self.busy = True
        self.toggle.configure(state="disabled", text="PROCESSANDO...")
        action = "stop" if self.state.cget("text") == "ONLINE" else "start"
        def work() -> None:
            code, output = systemctl(action)
            def done() -> None:
                self.busy = False
                if code != 0:
                    messagebox.showerror("Pixelmon GTS", output[-500:] or "Falha ao executar o comando.")
                self.refresh()
            self.after(0, done)
        threading.Thread(target=work, daemon=True).start()

    def open_panel(self) -> None:
        if self.current_url:
            webbrowser.open(self.current_url)


if __name__ == "__main__":
    Launcher().mainloop()
