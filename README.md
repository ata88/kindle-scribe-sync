# Scribe Sync ✍️ → 🖥

Eine native Mac-App, die deine **Kindle-Scribe-Notizbücher automatisch** auf den Mac holt. Die Handschrift wird **lokal mit KI** in Drucktext umgewandelt. Dazu ist weder Export noch Kabel noch ein Terminal nötig.

- **Eigene App:** Seitenbild neben dem erkannten Text, Ordner wie auf dem Scribe, Volltextsuche.
- **Korrigieren wie in Word:** Rechtschreibfehler sind rot unterstrichelt, ein Rechtsklick zeigt Vorschläge. Korrekturen werden gesichert, nach Apple Notes übertragen und bleiben erhalten, wenn du die Seite später auf dem Scribe ergänzt.
- **Apple Notes:** Jedes Notizbuch ist genau *eine* Notiz, die bei Änderungen aktualisiert wird.
- **Grafiken:** Zeichnungen und Skizzen werden als echtes Bild des jeweiligen Seitenbereichs eingebettet, nicht nur als Beschreibung.
- **KI direkt auf dem Mac:** Qwen 3.5 (9B) über Apple MLX. Kein Cloud-Dienst, keine Kosten. Das Modell ist nur im Arbeitsspeicher, während neue Seiten erkannt werden.

## Installation

1. Unter [Releases](https://github.com/ata88/kindle-scribe-sync/releases/latest) `ScribeSync-x.y.z.zip` laden und die App in den Ordner **Programme** ziehen.
2. Die App öffnen. Beim allerersten Start meldet macOS, dass die App nicht überprüft werden kann. Dann:
   **Systemeinstellungen › Datenschutz & Sicherheit › „Scribe Sync" wurde blockiert › Trotzdem öffnen**.
   Das ist nur einmal nötig. Der Grund: Die App ist mit einem eigenen Zertifikat signiert, nicht mit einem kostenpflichtigen Apple-Entwicklerkonto.
3. Die Einrichtung in der App folgt drei Schritten:
   1. **Bei Amazon anmelden.** Normale Zugangsdaten, auch für amazon.de-Konten.
   2. **KI-Modell laden.** Einmalig ca. 6 GB.
   3. Beim ersten Schreiben nach Notizen fragt macOS: „Scribe Sync möchte Notizen steuern" → **OK**.

Updates kommen danach automatisch: Die App fragt nach, zeigt, was neu ist, und installiert mit einem Klick.

**Voraussetzungen:**
- Mac mit Apple-Chip (M1 oder neuer)
- macOS 14 oder neuer
- 16 GB RAM empfohlen (für 8 GB gibt es ein kleineres Modell)

## So arbeitet die App

| | |
|---|---|
| **Wann synchronisiert sie?** | Alle 5 Minuten (einstellbar), solange die App läuft, und nach dem Aufwachen des Macs. Den Zeitpunkt wählt macOS so, dass möglichst wenig Energie verbraucht wird. |
| **Weckt sie den Mac?** | Nie. Im Ruhezustand passiert nichts. |
| **Akkubetrieb** | Einstellbar: normal weiterarbeiten (Texterkennung erst ab x % Akku), nur abrufen und am Netzteil erkennen, oder pausieren. Im Stromsparmodus wartet die Erkennung immer. |
| **Arbeitsspeicher** | Das KI-Modell (ca. 6 GB) wird nur geladen, wenn neue oder geänderte Seiten da sind, und danach sofort freigegeben. |
| **Fenster schließen** | Die App läuft weiter, das Symbol in der Menüleiste zeigt den Status. |
| **Beenden** | Über die Menüleiste oder das Dock. Danach läuft nichts mehr: keine Hintergrunddienste, keine Helfer-Prozesse. |
| **Diagnose** | Menü *Sync › Diagnose* (⌥⌘D) zeigt Zeitplan, Modell-Speicher, Energie, Amazon-Sitzung, Apple Notes und das komplette Aktivitätsprotokoll. |

### Korrekturen

Du tippst im Text einer Seite, und **⌘S** sichert. Die Notiz in Apple Notes wird sofort aktualisiert.

Schreibst du auf dem Scribe später weiter auf derselben Seite, liest die KI die Seite neu. Deine Korrekturen werden dabei per Drei-Wege-Abgleich auf Wortebene übernommen. Nur Wörter, die du korrigiert hast und die sich gleichzeitig im neuen Text geändert haben, behalten deine Fassung.

Bitte nicht direkt in Apple Notes korrigieren: Die Notiz wird bei der nächsten Änderung neu geschrieben.

### Wie kommen die Notizen vom Scribe?

Der Scribe synchronisiert seine Notizbücher selbst in die Amazon-Cloud. Für alle Länder liegen sie auf `read.amazon.com`. Die App nutzt die interne Schnittstelle von Kindle for Web:

| Endpunkt | Zweck |
|---|---|
| `GET /kindle-notebook/api/notes` | Ordner und Notizbücher |
| `GET /openNotebook?notebookId=…&marketplaceId=…` | Seitenzahl, Änderungszeit, Render-Token |
| `GET /renderPage?startPage=…` | Seiten als PNG |

Das ist eine **inoffizielle Schnittstelle**. Wenn Amazon sie ändert, zeigt die Diagnose den Fehler, und die App muss angepasst werden.

Daten verlassen deinen Mac nur zu Amazon (Notizbücher abrufen) und zu Hugging Face (einmaliger Modell-Download). Die Amazon-Anmeldung liegt im macOS-Schlüsselbund.

## Entwicklung

Der Code ist zweigeteilt:
- **`Sources/KSSCore`**: plattformunabhängige Logik (Amazon, Sync-Engine, Korrektur-Abgleich, Notes-HTML), getestet auf Linux und macOS mit `swift test`.
- **`App/`**: die SwiftUI-App (XcodeGen-Projekt), mit MLX für das Modell, Sparkle für Updates und AppleScript für Notizen.

Die App bauen (Xcode 26+, Apple-Chip):

```bash
brew install xcodegen
```

```bash
scripts/build-app.sh
```

Ein Release erstellen: Release-Notes in `docs/releases/<version>.md` ablegen, dann den Tag `vX.Y.Z` pushen. Der Workflow `.github/workflows/release.yml` baut, signiert und veröffentlicht App und Update-Feed. Er braucht die Repository-Secrets `SPARKLE_PRIVATE_KEY` und `SIGNING_CERT_P12`.

Den Umstieg vom früheren Kommandozeilen-Tool `kss` beschreibt [docs/MIGRATION.md](docs/MIGRATION.md).

Lizenz: MIT
