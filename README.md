# kindle-scribe-sync ✍️ → 🖥

Deine **Kindle-Scribe-Notizbücher landen automatisch auf dem Mac**. Kein Export,
kein Kabel, kein Antippen auf dem Scribe. Die Handschrift wird von **Claude**
(KI) in sauberen, kopierbaren Drucktext umgewandelt. Das Ergebnis erscheint in:

- **Apple Notes**: ein Ordner „Kindle Scribe“, deine Scribe-Ordner werden gespiegelt, mit Text und Seitenbild
- **einer lokalen Web-App** (http://127.0.0.1:8765): Seitenbild neben Text, Volltextsuche, „Kopieren“-Buttons, Dark Mode
- **Markdown-Dateien** in `~/Documents/Kindle Scribe` (passt zu Obsidian, Spotlight-durchsuchbar)

## Wie das funktioniert

```
Kindle Scribe ──WLAN-Sync──▶ Amazon Cloud ──▶ kss (alle 5 Min. auf deinem Mac)
                                                │  1. Notizbuch-Liste + Änderungszeit
                                                │  2. nur geänderte Notizbücher rendern
                                                │  3. nur geänderte Seiten → Claude (Vision)
                                                ▼
                                Apple Notes · Web-App · Markdown
```

Der Scribe synchronisiert Notizbücher von selbst in die Amazon-Cloud. Amazons
**Kindle for Web** zeigt sie über eine interne API an. `kss` nutzt dieselbe API
mit deiner normalen Amazon-Anmeldung:

| Endpunkt | Zweck |
|---|---|
| `GET /kindle-notebook/api/notes` | Ordner- und Notizbuchbaum |
| `GET /openNotebook?notebookId=…` | Seitenzahl, `modificationTime`, Rendering-Token |
| `GET /renderPage?startPage=…` | Seiten als PNG (tar) |

Damit es wenig kostet:

- Unveränderte Notizbücher werden übersprungen (`modificationTime`).
- Pro Seite wird ein Pixel-Hash gespeichert. Nur neue oder geänderte Seiten gehen an die KI.
- Fügst du mittendrin eine Seite ein, werden die vorhandenen Transkripte anhand des Hashs wiederverwendet.

## Installation (macOS)

Voraussetzung ist [uv](https://docs.astral.sh/uv/): `brew install uv`.

```bash
uv tool install git+https://github.com/<DEIN-USER>/kindle-scribe-sync
```

```bash
kss setup
```

`kss setup` erledigt alles in einem Durchgang:

1. **Amazon-Login** in einem Browserfenster. Den Haken bei „Angemeldet bleiben“ setzen. Region ist `us` (read.amazon.com), **auch für amazon.de-Konten** – nur dort gibt es die Notizbuch-API; einfach mit den normalen Zugangsdaten anmelden.
2. **KI wählen:** lokal mit Ollama (kostenlos) oder Claude per API-Key. Der Key wird im macOS-Schlüsselbund gespeichert.
3. **Ersten Sync** ausführen.
4. **Hintergrunddienste** (launchd) installieren: Sync alle 5 Minuten, Web-App dauerhaft.

Beim ersten Hintergrund-Sync fragt macOS, ob Python „Notizen“ steuern darf. Bitte **Erlauben**.

### Auf dem Scribe

Unter *Einstellungen → Geräteoptionen → Erweitert → Synchronisierung* die
Synchronisierung einschalten und WLAN aktiv lassen. Mehr ist nicht nötig.

## Befehle

| Befehl | |
|---|---|
| `kss setup` | geführte Einrichtung |
| `kss doctor` | prüft Login, API, Rendering und Key. Zuerst ausführen, wenn etwas hakt |
| `kss sync` | sofort synchronisieren (`--force` = alles neu, `--only "Titel"`) |
| `kss status` | Übersicht aller Notizbücher |
| `kss open` | Web-App öffnen |
| `kss login` | neu anmelden (falls die Amazon-Session abläuft, kommt eine Mitteilung) |
| `kss install` / `kss uninstall` | Hintergrunddienste an/aus |

## Konfiguration

Die Datei liegt unter `~/Library/Application Support/kindle-scribe-sync/config.toml`:

```toml
poll_interval = 300            # Sekunden
ocr_backend = "ollama"         # "ollama" (lokal) oder "claude"
ollama_model = "qwen3.5:9b"
model = "claude-opus-5-5"      # Modell für ocr_backend = "claude"
effort = "medium"              # "high" = noch gründlicher, teurer
language_hint = "Deutsch und Englisch"
apple_notes = true
apple_notes_account = "iCloud" # "" = Standardaccount
apple_notes_folder = "Kindle Scribe"
apple_notes_images = true      # Seitenbild unter dem Text
markdown_dir = "~/Documents/Kindle Scribe"   # "" = aus
render_width = 1240            # Render-Auflösung für die KI
render_height = 1754
```

Nach einer Änderung `kss install` erneut ausführen, damit launchd das neue Intervall übernimmt.

## KI: lokal (kostenlos) oder Claude (beste Qualität)

`kss setup` fragt, welche KI die Handschrift lesen soll. Umstellen kannst du jederzeit mit `kss local-setup` oder `kss use-claude`.

### Lokal mit Ollama (kostenlos, privat)

```bash
brew install ollama
```

```bash
kss local-setup
```

`kss local-setup` erkennt deinen Arbeitsspeicher, wählt ein passendes Modell und lädt es einmalig herunter:

| RAM | Modell | Download | Fehlerquote deutsche Handschrift* |
|---|---|---|---|
| ab 36 GB | `gemma4:31b` | ~20 GB | ~0,8 % |
| 16–32 GB | `qwen3.5:9b` | ~7 GB | ~1,6 % |
| 8 GB | `qwen3-vl:4b` | ~3 GB | deutlich schlechter |

\* Zeichenfehlerrate auf deutschen Handschrift-Scans laut [diesem Test](https://taggedsync.com/blog/best-local-model-for-handwriting) (Apple M5 Max, 4–9 s/Seite). Deine Handschrift kann abweichen.

**RAM-Verhalten:**

- Gibt es keine neuen Seiten, wird nichts geladen, Ollama wird gar nicht kontaktiert.
- Gibt es neue Seiten, wird das Modell für diesen einen Sync-Durchlauf geladen und danach **sofort entladen** (`keep_alive=0`).
- Läuft Ollama nicht, startet `kss` den Server selbst und beendet ihn danach wieder.
- Stürzt `kss` ab, wirft Ollama das Modell nach spätestens 2 Minuten selbst raus.

Ein anderes Modell wählst du mit `kss local-setup --model qwen3-vl:8b`.

### Claude über die API

Pro neu transkribierter Seite fallen grob **5 Cent** an (Claude Opus 5.5,
`effort = "medium"`). Unveränderte Seiten kosten nichts.

- Der API-Key ist **nicht** im Claude-Pro-Abo enthalten. Du brauchst ein Konto mit aufgeladenem Guthaben in der Claude Console.
- Max-, Ultra- und Team-Abos enthalten ein monatliches API-Guthaben.
- Etwa halb so teuer: `model = "claude-sonnet-5-5"`.

Ein Notizbuch später mit der anderen KI neu einlesen:

```bash
kss sync --force --only "Titel"
```

## Wichtig zu wissen

- **Inoffizielle API.** Amazon kann sie jederzeit ändern. Dann liefert `kss doctor` einen Fehler, und der Code muss angepasst werden. Anfragen laufen bewusst langsam und nacheinander.
- **Notizen in Apple Notes nicht bearbeiten.** Beim nächsten Sync des Notizbuchs wird die Notiz überschrieben. Zum Weiterarbeiten Text herauskopieren.
- **Gelöschte Notizbücher** werden nur als gelöscht markiert. Note und Markdown-Datei bleiben erhalten.
- **Sitzung.** Amazon-Cookies liegen nur lokal (`cookies.json`, Rechte 600). Läuft die Session ab, versucht `kss` sie still über das gespeicherte Browserprofil zu erneuern. Erst wenn das scheitert, kommt eine Mitteilung „kss login“.
- **Datenschutz.** Mit Ollama bleibt alles auf deinem Mac. Mit Claude gehen die Seitenbilder zur Transkription an die Anthropic API, sonst nirgendwohin.

## Optional: auf einem Server

Für einen Server (Linux) gilt:

- `kss sync` und `kss serve --host 0.0.0.0` laufen auch dort, am besten per systemd-Timer und hinter einem Reverse-Proxy mit Auth.
- Apple Notes funktioniert nur auf dem Mac. Auf dem Server gibt es Web-App und Markdown.
- `cookies.json` vom Mac kopieren oder `kss login` dort mit X-Forwarding ausführen.

## Entwicklung

```bash
uv venv && uv pip install -e '.[dev]'
```

```bash
.venv/bin/pytest
```

Die Tests laufen gegen einen nachgebauten Amazon-Server (`tests/fake_amazon.py`).
