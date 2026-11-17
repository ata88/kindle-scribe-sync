"""Command line: kss setup | login | set-key | sync | doctor | serve | install | uninstall | status"""

from __future__ import annotations

import argparse
import getpass
import io
import json
import logging
import logging.handlers
import sys
import time
import webbrowser

from . import __version__, apple_notes
from .amazon import AmazonClient, AmazonError, AuthExpired, CookieStore
from .config import Config, cookies_path, db_path, home_dir, log_dir
from .notify import notify
from .regions import AUTO_ORDER, REGIONS
from .store import Store

log = logging.getLogger("kss")


def _setup_logging(quiet: bool) -> None:
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    fh = logging.handlers.RotatingFileHandler(log_dir() / "kss.log", maxBytes=2_000_000, backupCount=3)
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root.addHandler(fh)
    if not quiet:
        sh = logging.StreamHandler()
        sh.setLevel(logging.WARNING)
        root.addHandler(sh)
    logging.getLogger("httpx").setLevel(logging.WARNING)


def _client(cfg: Config) -> AmazonClient:
    store = CookieStore(cookies_path())
    state = store.load()
    if not state.get("cookies"):
        raise AuthExpired("noch nicht angemeldet")
    region = state.get("region") or cfg.region
    return AmazonClient(region, store, request_delay=cfg.request_delay)


def make_transcriber(cfg: Config):
    """Created lazily by the syncer – only when there actually are new pages."""
    if cfg.ocr_backend == "ollama":
        from .ocr_local import OllamaTranscriber

        return OllamaTranscriber(model=cfg.ollama_model, url=cfg.ollama_url, languages=cfg.language_hint,
                                 num_ctx=cfg.ollama_num_ctx)
    from .ocr import ClaudeTranscriber

    return ClaudeTranscriber(model=cfg.model, effort=cfg.effort, languages=cfg.language_hint)


# -- commands -----------------------------------------------------------------

def cmd_login(args: argparse.Namespace, cfg: Config) -> int:
    from .login import LoginError, interactive_login

    region = args.region or _ask_region(cfg)
    print(f"Ein Browserfenster öffnet sich. Melde dich bei Amazon an (Häkchen bei „Angemeldet bleiben“ setzen!).")
    try:
        reg, n = interactive_login(region)
    except LoginError as e:
        print(f"✗ Login fehlgeschlagen: {e}")
        return 1
    cfg.region = reg.code
    cfg.save()
    print(f"✓ Angemeldet ({reg.read_host}). {n} Einträge in der obersten Ebene deiner Scribe-Notizbücher gefunden.")
    if n == 0:
        print("  Hinweis: 0 Einträge. Ist auf dem Scribe WLAN an und die Synchronisierung aktiv?\n"
              "  Sonst andere Region probieren, z. B. `kss login --region us`.")
    return 0


def _ask_region(cfg: Config) -> str:
    # read.amazon.com serves Scribe notebooks for accounts from every country (incl. amazon.de)
    default = cfg.region if cfg.region in REGIONS else "us"
    print("Hinweis: Scribe-Notizbücher liegen für alle Länder (auch amazon.de-Konten) auf read.amazon.com.\n"
          "Melde dich dort mit deinen normalen Amazon-Zugangsdaten an.")
    ans = input(f"Region [{', '.join(AUTO_ORDER)}] (Enter = {default}): ").strip().lower()
    return ans if ans in REGIONS else default


def cmd_set_key(args: argparse.Namespace, cfg: Config) -> int:
    from .ocr import store_api_key

    key = args.key or getpass.getpass("Anthropic API-Key (wird im macOS-Schlüsselbund gespeichert): ").strip()
    if not key.startswith("sk-"):
        print("Das sieht nicht wie ein Anthropic API-Key aus (beginnt mit sk-ant-…).")
        return 1
    store_api_key(key)
    print("✓ API-Key im Schlüsselbund gespeichert.")
    return 0


def _run_sync(cfg: Config, *, force: bool, only: str | None, quiet: bool) -> int:
    from .login import silent_refresh
    from .sync import SyncLocked, Syncer

    say = (lambda s: log.info(s)) if quiet else print
    store = Store(db_path())

    def factory():
        return make_transcriber(cfg)

    for attempt in range(2):
        try:
            with _client(cfg) as amazon:
                rep = Syncer(cfg, store, amazon, factory, log_fn=say).run(force=force, only=only)
            break
        except SyncLocked as e:
            say(str(e))
            return 0
        except AuthExpired as e:
            if attempt == 0 and cookies_path().exists():
                say("Amazon-Session abgelaufen – versuche stille Erneuerung …")
                if silent_refresh(CookieStore(cookies_path()).load().get("region", cfg.region)):
                    continue
            log.error("auth: %s", e)
            _notify_once(cfg, "auth", "Kindle Scribe Sync", "Amazon-Anmeldung abgelaufen. Terminal: kss login")
            print(f"✗ {e}\n  → `kss login` ausführen.", file=sys.stderr)
            return 2
        except AmazonError as e:
            log.error("amazon: %s", e)
            print(f"✗ Amazon: {e}", file=sys.stderr)
            return 1

    if rep.updated:
        names = ", ".join(rep.updated[:3]) + (" …" if len(rep.updated) > 3 else "")
        notify("Kindle Scribe", f"Aktualisiert: {names}", enabled=cfg.notify)
    if rep.errors:
        for e in rep.errors:
            log.warning(e)
        if not quiet:
            print("Fehler:\n  " + "\n  ".join(rep.errors), file=sys.stderr)
    say(f"Fertig: {rep.checked} Notizbücher geprüft, {len(rep.updated)} aktualisiert, "
        f"{rep.pages_transcribed} Seiten transkribiert.")
    return 1 if rep.errors and not rep.updated else 0


def _notify_once(cfg: Config, key: str, title: str, msg: str, every: int = 6 * 3600) -> None:
    f = home_dir() / f".notified-{key}"
    if f.exists() and time.time() - f.stat().st_mtime < every:
        return
    f.touch()
    notify(title, msg, enabled=cfg.notify)


def cmd_sync(args: argparse.Namespace, cfg: Config) -> int:
    return _run_sync(cfg, force=args.force, only=args.only, quiet=args.quiet)


def cmd_doctor(args: argparse.Namespace, cfg: Config) -> int:
    from PIL import Image

    from .ocr import resolve_api_key

    ok = True
    print(f"kindle-scribe-sync {__version__} · Daten: {home_dir()}")
    try:
        with _client(cfg) as amazon:
            print(f"• Region: {amazon.region.code} ({amazon.base_url})")
            items = amazon.list_items()
            print(f"✓ Amazon-Login gültig, {len(items)} Notizbücher gefunden")
            for it in items[:8]:
                path = " / ".join(it.folder_path)
                print(f"    - {path + ' / ' if path else ''}{it.title}")
            if items:
                meta = amazon.open_notebook(items[0].id)
                print(f"✓ Notizbuch öffnen: „{meta.title or items[0].title}“, {meta.total_pages} Seiten, "
                      f"geändert {meta.modification_time}")
                if meta.total_pages:
                    pngs = amazon.render_range(meta.rendering_token, 0, 0, width=cfg.render_width,
                                               height=cfg.render_height, dpi=cfg.render_dpi)
                    if pngs:
                        im = Image.open(io.BytesIO(pngs[0]))
                        print(f"✓ Seiten-Rendering: {im.width}×{im.height} px")
                    else:
                        ok = False
                        print("✗ Seiten-Rendering lieferte kein Bild")
                if args.verbose:
                    print(json.dumps(items[0].raw, indent=1, ensure_ascii=False))
                    print(json.dumps(meta.raw.get("metadata", {}), indent=1, ensure_ascii=False))
    except AuthExpired as e:
        ok = False
        print(f"✗ Amazon: {e} → `kss login`")
    except AmazonError as e:
        ok = False
        print(f"✗ Amazon: {e}")
    if cfg.ocr_backend == "ollama":
        import httpx

        try:
            httpx.get(cfg.ollama_url + "/api/version", timeout=3).raise_for_status()
            r = httpx.post(cfg.ollama_url + "/api/show", json={"model": cfg.ollama_model}, timeout=10)
            if r.status_code == 200:
                print(f"✓ Lokale KI: Ollama mit {cfg.ollama_model} (wird nur bei neuen Seiten geladen)")
            else:
                ok = False
                print(f"✗ Modell {cfg.ollama_model} fehlt → `kss local-setup`")
        except httpx.HTTPError:
            import shutil

            if shutil.which("ollama"):
                print(f"• Ollama läuft gerade nicht – wird beim Sync automatisch gestartet ({cfg.ollama_model})")
            else:
                ok = False
                print("✗ Ollama nicht installiert → https://ollama.com oder `brew install ollama`")
    elif resolve_api_key():
        print(f"✓ Anthropic API-Key vorhanden (Modell {cfg.model}, effort {cfg.effort})")
    else:
        ok = False
        print("✗ Kein Anthropic API-Key → `kss set-key` (oder lokal: `kss local-setup`)")
    if cfg.apple_notes:
        print("✓ Apple Notes aktiv" if apple_notes.available() else "• Apple Notes: nur auf macOS")
    if cfg.markdown_path:
        print(f"• Markdown-Export nach {cfg.markdown_path}")
    return 0 if ok else 1


def cmd_serve(args: argparse.Namespace, cfg: Config) -> int:
    from .web import serve

    if args.port:
        cfg.web_port = args.port
    if args.host:
        cfg.web_host = args.host
    serve(cfg)
    return 0


def cmd_install(args: argparse.Namespace, cfg: Config) -> int:
    from . import launchd

    paths = launchd.install(cfg, web=not args.no_web)
    for p in paths:
        print(f"✓ {p}")
    print(f"Sync läuft jetzt alle {cfg.poll_interval // 60} Minuten im Hintergrund"
          + ("" if args.no_web else f", Web-App: http://{cfg.web_host}:{cfg.web_port}"))
    return 0


def cmd_uninstall(args: argparse.Namespace, cfg: Config) -> int:
    from . import launchd

    launchd.uninstall()
    print("✓ Hintergrunddienste entfernt (Daten bleiben erhalten).")
    return 0


def cmd_status(args: argparse.Namespace, cfg: Config) -> int:
    store = Store(db_path())
    nbs = store.notebooks()
    print(f"{len(nbs)} Notizbücher · Daten in {home_dir()}")
    for n in nbs:
        flag = {"done": "✓", "partial": "◐", "error": "✗"}.get(n.status, "·")
        path = " / ".join(n.folder_path)
        print(f" {flag} {path + ' / ' if path else ''}{n.title} ({n.total_pages} S.)" + (f" – {n.error}" if n.error else ""))
    return 0


def cmd_open(args: argparse.Namespace, cfg: Config) -> int:
    webbrowser.open(f"http://{cfg.web_host}:{cfg.web_port}")
    return 0


def cmd_local_setup(args: argparse.Namespace, cfg: Config) -> int:
    """Switch to local transcription: check Ollama, pick a model for this Mac, download it."""
    import shutil
    import subprocess

    import httpx

    from .ocr import TranscriptionError
    from .ocr_local import OllamaTranscriber, pull_model, recommended_model, system_ram_gb

    if not shutil.which("ollama"):
        print("Ollama fehlt. Installieren mit `brew install ollama` oder von https://ollama.com – "
              "danach `kss local-setup` erneut ausführen.")
        return 1
    ram = system_ram_gb()
    model = args.model or recommended_model(ram)
    print(f"Arbeitsspeicher: {ram:.0f} GB → Modell {model}")
    if ram and ram < 16 and not args.model:
        print("  Hinweis: Mit unter 16 GB RAM ist die lokale Erkennung spürbar schwächer als Claude.")
    try:
        t = OllamaTranscriber(model=model, url=cfg.ollama_url, languages=cfg.language_hint)
        t.close()
        print(f"✓ {model} ist bereits vorhanden")
    except TranscriptionError as e:
        if "fehlt" not in str(e):
            print(f"✗ {e}")
            return 1
        print(f"Lade {model} herunter (einmalig, mehrere GB) …")
        proc = None  # make sure a server runs for the download
        try:
            httpx.get(cfg.ollama_url + "/api/version", timeout=3)
        except httpx.HTTPError:
            proc = subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            time.sleep(3)
        try:
            pull_model(model, cfg.ollama_url)
        finally:
            if proc:
                proc.terminate()
        print(f"✓ {model} installiert")
    cfg.ocr_backend = "ollama"
    cfg.ollama_model = model
    cfg.save()
    print("✓ Lokale Handschrifterkennung aktiv. Das Modell wird nur geladen, wenn neue Seiten da sind, "
          "und danach sofort aus dem RAM entfernt.")
    return 0


def cmd_use_claude(args: argparse.Namespace, cfg: Config) -> int:
    cfg.ocr_backend = "claude"
    cfg.save()
    print("✓ Claude-API aktiv. Tipp: `kss sync --force --only \"Titel\"` liest ein Notizbuch damit neu ein.")
    return 0


def cmd_setup(args: argparse.Namespace, cfg: Config) -> int:
    from .ocr import resolve_api_key

    print("== Kindle Scribe Sync – Einrichtung ==\n")
    if cmd_login(argparse.Namespace(region=None), cfg) != 0:
        return 1
    print("\nWelche KI soll die Handschrift lesen?\n"
          "  1) lokal auf diesem Mac (kostenlos, privat, Ollama – Modell nur während des Syncs im RAM)\n"
          "  2) Claude über die Anthropic API (beste Qualität, ca. 5 Cent/Seite, API-Key nötig)")
    choice = input("Auswahl [1]: ").strip() or "1"
    if choice == "1":
        if cmd_local_setup(argparse.Namespace(model=None), cfg) != 0:
            return 1
    else:
        cfg.ocr_backend = "claude"
        cfg.save()
        if not resolve_api_key():
            print("\nAPI-Key erstellen: platform.claude.com → API Keys (Guthaben vorher aufladen).")
            if cmd_set_key(argparse.Namespace(key=None), cfg) != 0:
                return 1
    print("\nErster Sync (kann bei vielen Seiten ein paar Minuten dauern) …")
    rc = _run_sync(cfg, force=False, only=None, quiet=False)
    if sys.platform == "darwin":
        print()
        cmd_install(argparse.Namespace(no_web=False), cfg)
        cmd_open(args, cfg)
    return rc


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="kss", description="Kindle Scribe → KI-Transkription → Apple Notes / Markdown / Web-App")
    p.add_argument("--version", action="version", version=__version__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("setup", help="Geführte Einrichtung (Login, API-Key, erster Sync, Hintergrunddienst)")
    s = sub.add_parser("login", help="Bei Amazon anmelden (Browserfenster)")
    s.add_argument("--region", choices=sorted(REGIONS), help="Amazon-Shop deines Kindle-Kontos")
    s = sub.add_parser("set-key", help="Anthropic API-Key im Schlüsselbund speichern")
    s.add_argument("key", nargs="?")
    s = sub.add_parser("local-setup", help="Lokale KI (Ollama) einrichten statt Claude-API")
    s.add_argument("--model", help="z. B. gemma4:31b, qwen3.5:9b, qwen3-vl:8b")
    s = sub.add_parser("use-claude", help="Zurück zur Claude-API wechseln")
    s = sub.add_parser("sync", help="Jetzt synchronisieren")
    s.add_argument("--force", action="store_true", help="Alles neu laden und neu transkribieren")
    s.add_argument("--only", help="Nur dieses Notizbuch (Titel oder ID)")
    s.add_argument("--quiet", action="store_true")
    s = sub.add_parser("doctor", help="Verbindung, Login und API-Key prüfen")
    s.add_argument("-v", "--verbose", action="store_true")
    s = sub.add_parser("serve", help="Web-App starten")
    s.add_argument("--port", type=int)
    s.add_argument("--host")
    s = sub.add_parser("install", help="Hintergrunddienste (launchd) installieren")
    s.add_argument("--no-web", action="store_true")
    sub.add_parser("uninstall", help="Hintergrunddienste entfernen")
    sub.add_parser("status", help="Synchronisierte Notizbücher anzeigen")
    sub.add_parser("open", help="Web-App im Browser öffnen")

    args = p.parse_args(argv)
    _setup_logging(quiet=getattr(args, "quiet", False))
    cfg = Config.load()
    handler = {
        "setup": cmd_setup, "login": cmd_login, "set-key": cmd_set_key, "sync": cmd_sync,
        "doctor": cmd_doctor, "serve": cmd_serve, "install": cmd_install, "uninstall": cmd_uninstall,
        "status": cmd_status, "open": cmd_open, "local-setup": cmd_local_setup, "use-claude": cmd_use_claude,
    }[args.cmd]
    try:
        return handler(args, cfg)
    except KeyboardInterrupt:
        return 130
