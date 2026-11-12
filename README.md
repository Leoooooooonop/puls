# PULS – PC-Tuning für Windows 10/11

Eine App mit Tweaks, Bloatware-Entfernung, DNS-Benchmark, Speicher-Analyse und Systemcheck.

| Tab | Was er macht |
|---|---|
| Übersicht | PULS-Score, Auslastung, Systeminfo, Ressourcenfresser |
| Tweaks | Leistung & Gaming (Game DVR, GPU-Planung, Drosselung, Ruhezustand …), Bedienung (Maus, Menüs, Einrastfunktion) |
| Windows aufräumen | Werbung, Copilot/Recall, Telemetrie (Dienste + Aufgaben), unnötige Dienste, Altlasten (IE-Modus, WordPad, SMB1, PowerShell 2 …), OneDrive – mit „Alles Empfohlene entfernen“-Knopf |
| Bloatware | Vorinstallierte Apps (News, Clipchamp, Candy Crush …) entfernen |
| DNS | Schnellsten DNS messen und sicher umstellen |
| Speicherplatz | Paralleler Ordner-Scan zum Durchklicken |
| Analyse | Laufwerks-Gesundheit, Bootzeiten, Fremddienste |

## Starten

PowerShell **als Administrator** öffnen und eingeben:

```powershell
irm https://raw.githubusercontent.com/Leoooooooonop/puls/main/puls.ps1 | iex
```

Ohne Adminrechte fragt PULS selbst nach (UAC-Fenster).

## Sicherheit

- Vor jedem Tweak, jeder Bloatware-Entfernung und jedem DNS-Wechsel wird automatisch ein **Windows-Wiederherstellungspunkt** erstellt.
- Jeder Originalwert wird in `%LOCALAPPDATA%\PULS` gesichert. „Rückgängig“ stellt genau den alten Zustand wieder her.
- DNS: Nach dem Umstellen wird sofort getestet. Geht das Internet nicht, wird automatisch zurückgestellt.
- Entfernte Apps lassen sich jederzeit über den Microsoft Store neu installieren.
