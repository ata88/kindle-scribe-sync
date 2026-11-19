# Scribe Sync ✍️ → 🖥

Eine native Mac-App, die deine **Kindle-Scribe-Notizbücher automatisch** auf den Mac holt. Die Handschrift wird **lokal mit KI** in Drucktext umgewandelt. Dazu ist weder Export noch Kabel noch ein Terminal nötig.

- **Eigene App mit drei Spalten wie Mail und Notizen:** intelligente Listen (Alle, Zuletzt geändert, Aufgaben, Zu prüfen), deine Scribe-Ordner und eine ruhige Leseansicht mit dem Originalscan als Inspektor.
- **Korrigieren wie in Word:** Rechtschreibfehler sind rot unterstrichelt, unsichere Stellen gelb markiert. Ein Doppelklick bearbeitet die Seite. Korrekturen gehen nach Apple Notes und bleiben erhalten, wenn du die Seite später auf dem Scribe ergänzt.
- **Apple Notes:** Jedes Notizbuch ist genau *eine* Notiz, die bei Änderungen aktualisiert wird – über iCloud auch auf dem iPhone.
- **Skizzen** werden als echtes Bild des jeweiligen Seitenbereichs eingebettet, an ihrer ursprünglichen Position.
- **Aufgaben:** Checkboxen aus allen Notizbüchern an einem Ort, direkt abhakbar.
- **KI direkt auf dem Mac:** Qwen 3.5 (9B) über Apple MLX. Kein Cloud-Dienst, keine Kosten. Das Modell ist nur im Arbeitsspeicher, während neue Seiten erkannt werden. Mit Live-Vorschau des gerade gelesenen Texts.
- **An Kindle senden:** EPUB, PDF, Word, Text oder Bilder in die App ziehen, auf das Dock-Symbol ziehen oder mit *Öffnen mit › Scribe Sync* öffnen. Sie landen drahtlos auf dem Kindle. PDFs bleiben im Original-Layout, auf dem Scribe kannst du darauf schreiben.
- **Spotlight, Mitteilungen, Export als Markdown** (mit den Skizzen als Bilddateien), Deutsch und Englisch umschaltbar.

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
| **Wann gleicht sie ab?** | Alle 5 Minuten (einstellbar), solange die App läuft – auch mit geschlossenem Fenster. Außerdem nach dem Aufwachen und beim Anschließen ans Netzteil. |
| **Am Netzteil** | Die App gleicht zuverlässig im Hintergrund ab und hält den Mac auf Wunsch wach (Bildschirm darf ausgehen), damit neue Notizen über iCloud auch unterwegs aufs iPhone kommen. Mit zugeklapptem Deckel schläft ein MacBook trotzdem. |
| **Weckt sie den Mac?** | Nie. Im Akkubetrieb wird der Mac weder geweckt noch wach gehalten. |
| **Akkubetrieb** | Einstellbar: normal weiterarbeiten (Texterkennung erst ab x % Akku), nur abrufen und am Netzteil erkennen, oder pausieren. Im Stromsparmodus wartet die Erkennung immer. |
| **Nicht lesbare Seiten** | Eine Seite, die die KI nicht lesen kann, wird dreimal automatisch erneut versucht, danach nur noch auf Wunsch (*Erneut versuchen*). So wird das Modell nicht ständig umsonst geladen. |
| **Arbeitsspeicher** | Das KI-Modell (ca. 6 GB) wird nur geladen, wenn neue oder geänderte Seiten da sind, und danach sofort freigegeben. |
| **Fenster schließen** | Die App läuft weiter, das Symbol in der Menüleiste zeigt den Status. |
| **Beenden** | Über die Menüleiste oder das Dock. Danach läuft nichts mehr: keine Hintergrunddienste, keine Helfer-Prozesse. |
| **Diagnose** | Menü *Abgleich › Diagnose* (⌥⌘D) zeigt Zeitplan, Modell-Speicher, Energie, Amazon-Sitzung, Apple Notes und das komplette Aktivitätsprotokoll. |

### Korrekturen

Ein Doppelklick auf eine Seite öffnet sie zum Bearbeiten, **⌘S** (oder ⌘↩) sichert. Die Notiz in Apple Notes wird sofort aktualisiert. Unter dem Menü *…* einer Seite lassen sich Korrekturen auch wieder zurücksetzen.

Schreibst du auf dem Scribe später weiter auf derselben Seite, liest die KI die Seite neu. Deine Korrekturen werden dabei per Drei-Wege-Abgleich auf Wortebene übernommen. Nur Wörter, die du korrigiert hast und die sich gleichzeitig im neuen Text geändert haben, behalten deine Fassung.

Bitte nicht direkt in Apple Notes korrigieren: Die Notiz wird bei der nächsten Änderung neu geschrieben.

### An Kindle senden

Bereich *Kindle › An Kindle senden* in der Seitenleiste. Es gibt zwei Wege, die Datei zu übertragen:

| | |
|---|---|
| **Direkt** (Standard) | Die App meldet sich einmal auf Amazons Anmeldeseite an, so wie Amazons eigene App „Send to Kindle für Mac“. Danach wählst du das Gerät, zum Beispiel deinen Scribe. Erlaubt sind EPUB, PDF, DOC(X), TXT, RTF, HTML und Bilder bis 200 MB. Titel und Autor liest die App aus der Datei. |
| **Per E-Mail** (Ausweichweg) | Die Datei geht als Anhang über die App Mail an deine persönliche `…@kindle.com`-Adresse, höchstens 50 MB. Deine Absenderadresse muss bei Amazon unter *Inhalte und Geräte › Einstellungen › Persönliche Dokumente* als genehmigt eingetragen sein. |

Dateien, die noch nicht gesendet sind, bleiben in der Warteschlange, auch über einen Neustart hinweg. Ein fehlgeschlagener Versand lässt sich mit *Erneut senden* wiederholen.

### Wie kommen die Notizen vom Scribe?

Der Scribe synchronisiert seine Notizbücher selbst in die Amazon-Cloud. Für alle Länder liegen sie auf `read.amazon.com`. Die App nutzt die interne Schnittstelle von Kindle for Web:

| Endpunkt | Zweck |
|---|---|
| `GET /kindle-notebook/api/notes` | Ordner und Notizbücher |
| `GET /openNotebook?notebookId=…&marketplaceId=…` | Seitenzahl, Änderungszeit, Render-Token |
| `GET /renderPage?startPage=…` | Seiten als PNG |

Das ist eine **inoffizielle Schnittstelle**. Wenn Amazon sie ändert, zeigt die Diagnose den Fehler, und die App muss angepasst werden.

Daten verlassen deinen Mac nur zu Amazon (Notizbücher abrufen, Dateien an den Kindle senden) und zu Hugging Face (einmaliger Modell-Download). Die Amazon-Anmeldung liegt im macOS-Schlüsselbund.

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

Ein Release erstellen: Release-Notes als `docs/releases/<version>.md` nach `main` bringen. Der Workflow `.github/workflows/release.yml` baut, signiert, legt den Tag `v<version>` an und veröffentlicht App und Update-Feed. Er braucht die Repository-Secrets `SPARKLE_PRIVATE_KEY` und `SIGNING_CERT_P12`.

Den Umstieg vom früheren Kommandozeilen-Tool `kss` beschreibt [docs/MIGRATION.md](docs/MIGRATION.md).

Lizenz: MIT
