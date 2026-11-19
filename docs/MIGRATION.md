# Umstieg vom Kommandozeilen-Tool `kss` auf die App Scribe Sync

Danach ist alles vom alten Tool entfernt, ohne Rückstände. Die alten Daten werden nicht übernommen: Die App liest deine Notizbücher frisch von Amazon. Das passiert lokal und kostet nichts.

Jeden Befehl einzeln ins Terminal kopieren. Zeigt ein Befehl „No such file" oder „not found" an, gab es das Teil bei dir nicht. Das ist in Ordnung.

## 1. Hintergrunddienste des alten Tools stoppen

```bash
kss uninstall
```

Prüfen, dass nichts mehr läuft. Die Ausgabe muss leer sein:

```bash
launchctl list | grep kindle-scribe-sync
```

Falls doch noch etwas erscheint, die zwei Dienste von Hand entfernen:

```bash
launchctl bootout gui/$(id -u)/com.github.kindle-scribe-sync.sync; launchctl bootout gui/$(id -u)/com.github.kindle-scribe-sync.web
```

```bash
rm -f ~/Library/LaunchAgents/com.github.kindle-scribe-sync.*.plist
```

## 2. Das Programm `kss` entfernen

```bash
uv tool uninstall kindle-scribe-sync
```

## 3. Daten des alten Tools löschen

Gelöscht werden Amazon-Cookies, Datenbank, Seitenbilder, Logs und das Browser-Profil.

```bash
rm -rf ~/Library/Application\ Support/kindle-scribe-sync
```

Den heruntergeladenen Quellcode löschen:

```bash
rm -rf ~/kindle-scribe-sync
```

Falls der Login-Browser heruntergeladen wurde, den Browser-Cache löschen:

```bash
rm -rf ~/Library/Caches/ms-playwright
```

Den Markdown-Export löschen, falls du ihn nicht behalten willst:

```bash
rm -rf ~/Documents/Kindle\ Scribe
```

## 4. Ollama und das alte KI-Modell entfernen (ca. 7 GB)

Die App bringt ihre eigene KI mit, Ollama wird nicht mehr gebraucht.

```bash
pkill -x ollama; brew uninstall ollama
```

```bash
rm -rf ~/.ollama
```

## 5. Nicht mehr benötigte Werkzeuge (optional)

`uv` und `gh` wurden nur für das alte Tool installiert. Falls du sie sonst nicht nutzt, erst bei GitHub abmelden:

```bash
gh auth logout
```

Dann beide entfernen:

```bash
brew uninstall uv gh
```

```bash
rm -rf ~/.local/share/uv ~/.cache/uv
```

## 6. Alte Notizen in Apple Notes löschen

Das alte Tool hat bei Änderungen teils neue Notizen angelegt, statt die bestehenden zu aktualisieren. Damit die App sauber startet:

1. Die App **Notizen** öffnen.
2. Den Ordner **Kindle Scribe** auswählen, Rechtsklick › **Ordner löschen**.

Die App legt ihn neu an, mit genau einer Notiz pro Notizbuch.

Die alte Berechtigung „Terminal → Notizen" kannst du entfernen: Systemeinstellungen › Datenschutz & Sicherheit › Automation › Terminal › Haken bei „Notizen" entfernen.

## 7. App installieren

1. [Neueste Version laden](https://github.com/ata88/kindle-scribe-sync/releases/latest): `ScribeSync-….zip` anklicken. Safari entpackt die Datei automatisch.
2. **Scribe Sync** aus dem Ordner „Downloads" in den Ordner **Programme** ziehen.
3. Die App öffnen.
   - Erscheint die Meldung *„Scribe Sync" kann nicht geöffnet werden*: **Fertig** klicken.
   - Dann **Systemeinstellungen › Datenschutz & Sicherheit** öffnen und nach unten scrollen bis „Scribe Sync wurde blockiert".
   - Dort **Trotzdem öffnen** wählen und mit dem Passwort oder Touch ID bestätigen.
   - Das ist nur beim allerersten Start nötig.
4. Den Schritten in der App folgen:
   1. **Bei Amazon anmelden.** Normale Zugangsdaten, „Angemeldet bleiben" ankreuzen.
   2. **KI-Modell laden.** Ca. 6 GB, einmalig.
   3. Die Frage „Scribe Sync möchte Notizen steuern" mit **OK** bestätigen.
5. Optional: **Scribe Sync › Einstellungen › Allgemein › „Beim Anmelden am Mac öffnen"**.

Fertig. Ab jetzt läuft alles in der App, und Updates kommen über *Scribe Sync › Nach Updates suchen*.

## Von 1.0 auf 1.1

Nichts zu tun, das Update kommt über *Scribe Sync › Nach Updates suchen*. Beim ersten Abgleich schreibt 1.1 alle Notizen einmal neu:

- Skizzen erscheinen dann als echte Bilder statt als „Datei“-Block.
- Es bleibt weiterhin genau eine Notiz pro Notizbuch.

Die Sprache stellst du in *Einstellungen › Allgemein* ein. Die Menüs wechseln nach einem Neustart der App.

## Von 1.1 auf 1.1.1

Auch hier ist nichts zu tun, das Update kommt über *Scribe Sync › Nach Updates suchen*. Nach dem Update passiert automatisch:

- Alle Notizen werden einmal neu geschrieben. Danach zeigen sie die Skizzen als echte Bilder.
- Bereits erkannte Skizzen werden einmal neu ausgeschnitten. Die Texterkennung läuft dafür nicht noch einmal.

Bis 1.1.0 hat die App bei jeder Änderung die Notiz neu angelegt. Die alten Fassungen liegen in Notizen im Ordner **Zuletzt gelöscht**. Du kannst sie dort gefahrlos löschen: Ordner auswählen, Rechtsklick › **Alle löschen**.

## Später: die App vollständig entfernen

1. Die App über die Menüleiste beenden und in den Papierkorb ziehen.
2. Die Daten der App löschen. Das sind Bibliothek, KI-Modell, Protokoll und die Anmeldedaten im WebKit-Speicher:
   - `~/Library/Application Support/Scribe Sync`
   - `~/Library/WebKit/io.github.ata88.scribesync`
   - `~/Library/Caches/io.github.ata88.scribesync`
   - In der Schlüsselbundverwaltung den Eintrag „io.github.ata88.scribesync" löschen.
