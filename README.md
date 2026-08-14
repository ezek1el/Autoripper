# ezek1el3000's AutoRip

Automatisches Rippen von Video-DVDs, Blu-rays, Video-CDs und Daten-Discs nach MKV unter Windows.
Disc einlegen → Ordner wird angelegt → MKV landet darin → Disc wird ausgeworfen. Nächste Disc.

Zwei Varianten im Repo:

| Datei | Beschreibung |
|---|---|
| `AutoRipGUI.ps1` | WPF-Oberfläche mit Fortschrittsbalken, Restzeit und Protokoll (empfohlen) |
| `AutoRip.ps1` | Reine Konsolenversion, identische Logik |

## Funktionen

- Erkennt automatisch DVD (`VIDEO_TS`), Blu-ray (`BDMV`), Video-CD (`MPEGAV`), Super-Video-CD (`MPEG2`)
- Fallback für Daten-Discs: sammelt lose Videodateien (avi, mpg, mp4, wmv, vob …) ein und remuxt sie
- Verlustfreies Rippen über MakeMKV, kein Re-Encode
- Ordnername aus dem Disc-Label, Kollisionen bekommen einen Zeitstempel
- Fortschritt in Prozent, verstrichene Zeit, geschätzte Restzeit
- Stillstands-Indikator: zeigt an, wenn das Laufwerk länger keine Daten liefert
- Automatischer Auswurf nach dem Rippen (abschaltbar)
- USB-Laufwerke werden wie interne behandelt

## Voraussetzungen

- Windows 10/11, PowerShell 5.1 oder neuer
- [MakeMKV](https://www.makemkv.com/) für DVDs und Blu-rays. Einmal die GUI starten und den kostenlosen Beta-Key eintragen (steht im MakeMKV-Forum, muss ca. monatlich erneuert werden). `makemkvcon.exe` wird automatisch in den Standardpfaden gefunden.
- [ffmpeg](https://ffmpeg.org/) nur für Video-CDs und Daten-Discs:
  ```
  winget install Gyan.FFmpeg
  ```

## Start

GUI:

```
powershell -NoProfile -ExecutionPolicy Bypass -File AutoRipGUI.ps1
```

Das Script koppelt sich beim Start vom Konsolenfenster ab. Das aufrufende Terminal kann sofort geschlossen werden, die Oberfläche läuft weiter. Flackerfrei per Doppelklick geht es mit dem beiliegenden `AutoRip.vbs` (Pfad darin anpassen).

Konsolenversion:

```
powershell -NoProfile -ExecutionPolicy Bypass -File AutoRip.ps1
```

## Konfiguration

**GUI:** Zielordner, minimale Titellänge und Auswurf-Verhalten direkt im Fenster. Die Einstellungen liegen in `%APPDATA%\AutoRip\settings.json`.

**Konsole:** Variablenblock am Anfang von `AutoRip.ps1`.

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `OutputRoot` | `E:\Rips` | Zielordner für alle Rips |
| `MinLength` | `120` | Titel unter dieser Länge (Sekunden) werden übersprungen. Filtert Trailer und Menüs. Bei reinen Spielfilm-DVDs kann der Wert auf 1200 hoch, bei Serien-DVDs so lassen. |
| `Eject` | `true` | Disc nach dem Rippen auswerfen |

## Fehlerbehebung

**„Ungültige Win32-FileTime"** – Behoben. Alte gebrannte Discs haben oft kaputte Zeitstempel, an denen sich `Test-Path` und `Get-ChildItem` unter PowerShell 5.1 verschlucken. Alle Disc-Zugriffe laufen deshalb über `System.IO`.

**Es tut sich minutenlang nichts** – Solange der Spinner läuft, arbeitet das Script. Erscheint zusätzlich „keine Ausgabe seit Xs", kämpft das Laufwerk mit Lesefehlern; bei zerkratzten Discs können das durchaus 10 Minuten Retry sein. Details stehen in `_makemkv.log` im Zielordner.

**Keine MKVs im Zielordner** – `_makemkv.log` bzw. `_ffmpeg.log` im jeweiligen Ordner prüfen. Bei MakeMKV ist meistens der abgelaufene Beta-Key die Ursache.

**Die GUI startet nicht** – Zur Fehlersuche mit sichtbarer Konsole starten:

```
powershell -NoProfile -ExecutionPolicy Bypass -File AutoRipGUI.ps1 -ShowConsole
```

## Hinweise

Gerippt wird verlustfrei, eine DVD landet also bei 4–8 GB pro MKV. Fürs anschließende Eindampfen auf H.265 eignet sich z. B. [Tdarr](https://home.tdarr.io/) oder HandBrake.

Das Tool ist für das Sichern eigener, rechtmäßig erworbener Datenträger gedacht. Die Rechtslage zum Umgehen von Kopierschutz unterscheidet sich je nach Land — in Deutschland ist das Umgehen eines wirksamen Kopierschutzes auch für Privatkopien nach § 95a UrhG nicht zulässig.

## Lizenz

MIT — siehe [LICENSE](LICENSE).

---

Repo: [github.com/ezek1el/Autoripper](https://github.com/ezek1el/Autoripper)
