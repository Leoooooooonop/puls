# =====================================================================
#  PULS - PC-Tuning-App fuer Windows 10/11
#  Online starten:  irm https://raw.githubusercontent.com/Leoooooooonop/puls/main/puls.ps1 | iex
#  Lokal starten:   start.cmd
# =====================================================================
$PulsUrl = 'https://raw.githubusercontent.com/Leoooooooonop/puls/main/puls.ps1'

# ---------- Adminrechte + Windows PowerShell (STA) sicherstellen ----------
$pulsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$pulsSta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $env:PULS_OHNE_ADMIN -and (-not $pulsAdmin -or -not $pulsSta -or $PSVersionTable.PSEdition -eq 'Core')) {
    if ($env:PULS_PFAD -and (Test-Path -LiteralPath $env:PULS_PFAD)) {
        $pulsStart = "`$env:PULS_PFAD='$($env:PULS_PFAD.Replace("'", "''"))'; iex ([IO.File]::ReadAllText(`$env:PULS_PFAD, [Text.Encoding]::UTF8))"
    } else {
        $pulsStart = "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm '$PulsUrl' | iex"
    }
    $pulsEnc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pulsStart))
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -EncodedCommand $pulsEnc" }
    catch { Write-Host 'PULS braucht Adminrechte - abgebrochen.' -ForegroundColor Red }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:IstAdmin = $pulsAdmin
$script:IstLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$script:Ablage = Join-Path $env:LOCALAPPDATA 'PULS'
$script:BackupDatei = Join-Path $script:Ablage 'tweaks-backup.json'
$script:DnsBackup = Join-Path $script:Ablage 'dns-backup.json'
$script:Jobs = New-Object System.Collections.ArrayList
$script:Busy = $false

# ---------- Schneller paralleler Ordner-Scanner (einmal scannen, dann sofort navigieren) ----------
if (-not ('PulsScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Collections.Generic; using System.Threading; using System.Threading.Tasks;
public class PulsNode {
    public string Name; public string Path; public long Size; public long Files;
    public List<PulsNode> Kids = new List<PulsNode>(); public PulsNode Parent;
}
public static class PulsScan {
    public static int Ordner;
    public static PulsNode Scan(string root) {
        Ordner = 0;
        var n = new PulsNode(); n.Name = root; n.Path = root;
        Fill(n, 0);
        return n;
    }
    static void Fill(PulsNode n, int depth) {
        var subs = new List<PulsNode>(); long files = 0;
        try {
            foreach (var e in new DirectoryInfo(n.Path).EnumerateFileSystemInfos()) {
                if ((e.Attributes & FileAttributes.Directory) != 0) {
                    if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    var k = new PulsNode(); k.Name = e.Name; k.Path = e.FullName; k.Parent = n; subs.Add(k);
                } else { files += ((FileInfo)e).Length; }
            }
        } catch { }
        Interlocked.Increment(ref Ordner);
        if (depth < 3) Parallel.ForEach(subs, s => Fill(s, depth + 1));
        else foreach (var s in subs) Fill(s, depth + 1);
        long total = files; foreach (var s in subs) total += s.Size;
        n.Files = files; n.Kids = subs; n.Size = total;
    }
}
'@
}

# ---------- Allgemeine Helfer ----------
function Fmt([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) }
}
function Farbe-Pct([double]$p) { if ($p -ge 85) { '#FF5C5C' } elseif ($p -ge 65) { '#FFB547' } else { '#00D1B2' } }
function T([string]$text, [double]$size = 13, [string]$farbe = '#E6E6EA', [switch]$Fett, [string]$m = '0') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = $farbe; $t.TextWrapping = 'Wrap'; $t.Margin = $m
    if ($Fett) { $t.FontWeight = 'SemiBold' }
    $t
}
function Karte([string]$titel) {
    $b = New-Object Windows.Controls.Border
    $b.Background = '#1D1D23'; $b.CornerRadius = '10'; $b.Padding = '18,14'; $b.Margin = '0,0,0,12'
    $b.Child = New-Object Windows.Controls.StackPanel
    if ($titel) { [void]$b.Child.Children.Add((T $titel 15 '#FFFFFF' -Fett -m '0,0,0,10')) }
    $b
}
function Balken([double]$pct, [string]$farbe) {
    $pct = [math]::Max(0, [math]::Min(100, $pct))
    $g = New-Object Windows.Controls.Grid; $g.Height = 8; $g.VerticalAlignment = 'Center'
    foreach ($w in @([math]::Max($pct, 0.001), [math]::Max(100 - $pct, 0.001))) {
        $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = New-Object Windows.GridLength($w, 'Star'); [void]$g.ColumnDefinitions.Add($c)
    }
    $bg = New-Object Windows.Controls.Border; $bg.Background = '#2A2A33'; $bg.CornerRadius = '4'; [Windows.Controls.Grid]::SetColumnSpan($bg, 2)
    $fg = New-Object Windows.Controls.Border; $fg.Background = $farbe; $fg.CornerRadius = '4'
    [void]$g.Children.Add($bg); [void]$g.Children.Add($fg)
    $g
}
function Zeile([string]$label, [double]$pct, [string]$wert, [string]$farbe, [int]$lb = 220) {
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,3'
    foreach ($w in @("$lb", '*', '190')) { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
    $a = T $label; $a.TextWrapping = 'NoWrap'; $a.TextTrimming = 'CharacterEllipsis'
    $bar = Balken $pct $farbe; $bar.Margin = '10,0'; [Windows.Controls.Grid]::SetColumn($bar, 1)
    $c = T $wert 13 '#B8B8C4'; $c.TextAlignment = 'Right'; [Windows.Controls.Grid]::SetColumn($c, 2)
    [void]$g.Children.Add($a); [void]$g.Children.Add($bar); [void]$g.Children.Add($c)
    $g
}
function Log([string]$m, [string]$art = 'info') {
    $zeichen = @{ ok = '[OK]'; fehler = '[FEHLER]'; warn = '[!]'; info = '' }[$art]
    $ui.Log.AppendText(("[{0:HH:mm:ss}] {1} {2}`r`n" -f (Get-Date), $zeichen, $m).Replace('  ', ' '))
    $ui.Log.ScrollToEnd()
}
function Set-Busy([bool]$b) {
    $script:Busy = $b
    foreach ($n in 'BtnTweakAn', 'BtnTweakAus', 'BtnBloatEntfernen', 'BtnDnsReset') { $ui[$n].IsEnabled = -not $b }
}
function Start-Bg([scriptblock]$Arbeit, [object[]]$Argumente, [scriptblock]$Fertig) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Arbeit.ToString())
    foreach ($a in $Argumente) { [void]$ps.AddArgument($a) }
    [void]$script:Jobs.Add(@{ Ps = $ps; H = $ps.BeginInvoke(); Fertig = $Fertig })
}

# ---------- Wiederherstellungspunkt vor jeder Aenderung ----------
$bgRestore = {
    param($beschreibung)
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $alt = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -ErrorAction Stop   # 24-h-Sperre kurz aufheben
        Checkpoint-Computer -Description $beschreibung -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        'OK'
    } catch { "FEHLER: $($_.Exception.Message)" }
    finally {
        if ($null -eq $alt) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $alt -Type DWord -ErrorAction SilentlyContinue }
    }
}
function Mit-Restorepunkt([string]$wozu, [scriptblock]$dann) {
    if ($script:Busy) { Log 'Es läuft noch eine Aktion - kurz warten.' 'warn'; return }
    if (-not $script:IstAdmin) { Log 'Ohne Adminrechte kein Wiederherstellungspunkt möglich - abgebrochen.' 'fehler'; return }
    Set-Busy $true
    $script:NachRp = $dann
    Log "Erstelle Wiederherstellungspunkt vor: $wozu (dauert 10-60 s) ..."
    Start-Bg $bgRestore @("PULS: $wozu") {
        param($res)
        $r = [string](@($res) | Select-Object -Last 1)
        $weiter = $true
        if ($r -eq 'OK') { Log 'Wiederherstellungspunkt erstellt.' 'ok' }
        else {
            Log "Wiederherstellungspunkt fehlgeschlagen: $r" 'fehler'
            $a = [Windows.MessageBox]::Show("Der Wiederherstellungspunkt konnte nicht erstellt werden:`n$r`n`nTrotzdem fortfahren?", 'PULS', 'YesNo', 'Warning')
            $weiter = ($a -eq 'Yes')
        }
        Set-Busy $false
        if ($weiter) { & $script:NachRp } else { Log 'Abgebrochen - nichts geändert.' }
    }
}

# ---------- Tweaks ----------
function RW($p, $n, $v, $t = 'DWord') { [pscustomobject]@{ P = $p; N = $n; V = $v; T = $t } }
function Reg-Lesen($pfad, $name) {
    try {
        $k = Get-Item -Path $pfad -ErrorAction Stop
        $v = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
        if ($null -eq $v) { return $null }
        [pscustomobject]@{ Wert = $v; Typ = [string]$k.GetValueKind($name) }
    } catch { $null }
}
function Lade-Backup {
    $h = @{}
    if (Test-Path $script:BackupDatei) {
        try { foreach ($e in (Get-Content $script:BackupDatei -Raw | ConvertFrom-Json)) { if ($e.Key) { $h[$e.Key] = $e } } } catch {}
    }
    $h
}
function Speichere-Backup($h) {
    if (-not (Test-Path $script:Ablage)) { New-Item -ItemType Directory -Path $script:Ablage -Force | Out-Null }
    ConvertTo-Json -InputObject @($h.Values) -Depth 4 | Set-Content -Path $script:BackupDatei -Encoding UTF8
}

$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$games = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
$kL = 'Leistung & Gaming'; $kB = 'Bedienung'; $kW = 'Windows-Bloat & Datenschutz'
$script:Tweaks = @(
    @{ Id = 'gamedvr'; Kat = $kL; Name = 'Xbox-Hintergrundaufnahme aus'; Wirkt = 'beim nächsten Spielstart'; Empf = $true
       Warum = 'Game DVR zeichnet sonst ständig im Hintergrund mit - kostet FPS und macht Frametime-Spikes.'
       Reg = @((RW 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0), (RW 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0)) },
    @{ Id = 'hags'; Kat = $kL; Name = 'Hardware-GPU-Planung an'; Wirkt = 'nach Neustart'; Empf = $true
       Warum = 'Die GPU verwaltet ihren Speicher selbst: weniger CPU-Last und Latenz. Pflicht für DLSS Frame Generation.'
       Reg = @((RW 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2)) },
    @{ Id = 'drossel'; Kat = $kL; Name = 'Leistungsdrosselung aus'; Wirkt = 'nach Neustart'; Empf = (-not $script:IstLaptop)
       Warum = 'Windows schiebt Hintergrundprogramme (Discord, OBS, Medal) nicht mehr auf Spar-Takt. Auf Laptops kostet das Akku.'
       Reg = @((RW 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1)) },
    @{ Id = 'mmcss'; Kat = $kL; Name = 'Spiele-Priorität im Scheduler'; Wirkt = 'nach Neustart'; Empf = $true
       Warum = 'Weniger CPU-Reserve für Hintergrundaufgaben, höhere Thread-/GPU-Priorität für Spiele. Hilft eher gegen Ruckler als für mehr FPS.'
       Reg = @((RW 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10), (RW $games 'GPU Priority' 8),
               (RW $games 'Priority' 6), (RW $games 'Scheduling Category' 'High' 'String'), (RW $games 'SFIO Priority' 'High' 'String')) },
    @{ Id = 'schnellstart'; Kat = $kL; Name = 'Schnellstart aus'; Wirkt = 'ab nächstem Herunterfahren'; Empf = $true
       Warum = '"Herunterfahren" wird ein echter Neustart: kein verschleppter RAM-/Treibermüll über Tage. Boot minimal langsamer.'
       Reg = @((RW 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0)) },
    @{ Id = 'ruhezustand'; Kat = $kL; Name = 'Ruhezustand aus (Speicherplatz frei)'; Wirkt = 'sofort'; Empf = (-not $script:IstLaptop)
       Warum = 'Löscht hiberfil.sys (Größe hängt am RAM). Energiesparen/Standby geht weiter, nur "Ruhezustand" fällt weg.'
       Extra = { $f = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue; if ($f) { "Gibt aktuell $(Fmt $f.Length) frei." } }
       Ist = { (Reg-Lesen 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled').Wert -eq 0 }
       An = { powercfg /h off; if ($LASTEXITCODE) { throw 'powercfg /h off fehlgeschlagen' } }
       Aus = { powercfg /h on; if ($LASTEXITCODE) { throw 'powercfg /h on fehlgeschlagen' } } },

    @{ Id = 'maus'; Kat = $kB; Name = 'Mausbeschleunigung aus'; Wirkt = 'nach Abmelden'; Empf = $true
       Warum = 'Gleiche Handbewegung = gleiche Strecke. Spiele mit Raw Input ignorieren das, Menüs und Desktop nicht.'
       Reg = @((RW 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'), (RW 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'), (RW 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String')) },
    @{ Id = 'menue'; Kat = $kB; Name = 'Menü-Verzögerung weg'; Wirkt = 'nach Abmelden'; Empf = $true
       Warum = 'Untermenüs öffnen sofort statt nach einer eingebauten 400-ms-Pause.'
       Reg = @((RW 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String')) },

    @{ Id = 'werbung'; Kat = $kW; Name = 'Windows-Werbung & Vorschläge aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Keine App-Vorschläge und "Empfohlen"-Werbung im Startmenü, keine Tipps-Popups, keine Sperrbildschirm-Werbung, keine still nachinstallierten Apps.'
       Reg = @((RW $cdm 'SubscribedContent-338388Enabled' 0), (RW $cdm 'SubscribedContent-338389Enabled' 0), (RW $cdm 'SubscribedContent-353694Enabled' 0),
               (RW $cdm 'SubscribedContent-353696Enabled' 0), (RW $cdm 'SubscribedContent-338387Enabled' 0), (RW $cdm 'RotatingLockScreenOverlayEnabled' 0),
               (RW $cdm 'SystemPaneSuggestionsEnabled' 0), (RW $cdm 'SilentInstalledAppsEnabled' 0), (RW $cdm 'SoftLandingEnabled' 0),
               (RW $adv 'ShowSyncProviderNotifications' 0), (RW $adv 'Start_IrisRecommendations' 0)) },
    @{ Id = 'websuche'; Kat = $kW; Name = 'Bing-Websuche im Startmenü aus'; Wirkt = 'nach Explorer-Neustart'; Empf = $true
       Warum = 'Startmenü sucht nur noch lokal: schneller, ohne Bing-Treffer.'
       Reg = @((RW 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1), (RW 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0)) },
    @{ Id = 'widgets'; Kat = $kW; Name = 'Widgets / News-Feed aus'; Wirkt = 'nach Explorer-Neustart'; Empf = $true
       Warum = 'Entfernt das Wetter-/News-Panel aus der Taskleiste samt seinen Hintergrundprozessen (WebView).'
       Reg = @((RW 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0)) },
    @{ Id = 'copilot'; Kat = $kW; Name = 'Copilot aus'; Wirkt = 'nach Explorer-Neustart'; Empf = $true
       Warum = 'Schaltet Windows Copilot und den Taskleisten-Knopf ab. Die Copilot-App selbst entfernst du unter "Bloatware".'
       Reg = @((RW 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1), (RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1),
               (RW $adv 'ShowCopilotButton' 0)) },
    @{ Id = 'recall'; Kat = $kW; Name = 'Recall / KI-Bildschirmfotos aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Verhindert, dass Windows laufend Screenshots deines Bildschirms speichert und auswertet (Copilot+-PCs).'
       Reg = @((RW 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1), (RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1),
               (RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0)) },
    @{ Id = 'hintergrund'; Kat = $kW; Name = 'Hintergrund-Apps aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Store-Apps (Wetter, Fotos, Xbox ...) laufen nicht mehr unsichtbar weiter. Normale Programme sind nicht betroffen.'
       Reg = @((RW 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1), (RW 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0)) },
    @{ Id = 'telemetrie'; Kat = $kW; Name = 'Hintergrund-Uploads (Telemetrie-Dienst) aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Stoppt den Dienst "Benutzererfahrung und Telemetrie" (DiagTrack): keine Hintergrund-Uploads und Datenträgerlast mehr.'
       Ist = { (Get-Service DiagTrack -ErrorAction Stop).StartType -eq 'Disabled' }
       An = { Stop-Service DiagTrack -Force -ErrorAction Stop; Set-Service DiagTrack -StartupType Disabled -ErrorAction Stop }
       Aus = { Set-Service DiagTrack -StartupType Automatic -ErrorAction Stop; Start-Service DiagTrack -ErrorAction SilentlyContinue } },
    @{ Id = 'diagdaten'; Kat = $kW; Name = 'Diagnosedaten auf Minimum'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Windows schickt nur noch die Pflicht-Diagnosedaten statt der optionalen (Nutzung, Apps, Browser).'
       Reg = @((RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0)) },
    @{ Id = 'werbeid'; Kat = $kW; Name = 'Werbe-ID & personalisierte Tipps aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Apps bekommen keine Werbe-ID mehr, Microsoft nutzt deine Diagnosedaten nicht für "maßgeschneiderte" Werbung.'
       Reg = @((RW 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0), (RW 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0)) },
    @{ Id = 'aktivitaet'; Kat = $kW; Name = 'Aktivitätsverlauf aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Windows protokolliert nicht mehr, welche Programme und Dateien du wann geöffnet hast.'
       Reg = @((RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0), (RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0),
               (RW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0)) },
    @{ Id = 'feedback'; Kat = $kW; Name = 'Feedback-Anfragen aus'; Wirkt = 'sofort'; Empf = $true
       Warum = 'Keine "Wie gefällt dir Windows?"-Popups mehr.'
       Reg = @((RW 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0)) }
)

function Tweak-Ist($t) {
    if ($t.Ist) { try { return [bool](& $t.Ist) } catch { return $false } }
    foreach ($r in $t.Reg) {
        $a = Reg-Lesen $r.P $r.N
        if ($null -eq $a -or [string]$a.Wert -ne [string]$r.V) { return $false }
    }
    $true
}
function Tweak-VonUns($t, $bk) {
    if (-not $t.Reg) { return $bk.ContainsKey("befehl|$($t.Id)") }
    foreach ($r in $t.Reg) { if ($bk.ContainsKey("$($r.P)|$($r.N)")) { return $true } }
    $false
}
function Tweak-Setzen($t, [bool]$an, $bk) {
    try {
        if ($t.Reg) {
            if ($an) {
                foreach ($r in $t.Reg) {
                    $key = "$($r.P)|$($r.N)"
                    if ($bk.ContainsKey($key)) { continue }
                    $alt = Reg-Lesen $r.P $r.N
                    $e = [pscustomobject]@{ Key = $key; P = $r.P; N = $r.N; Da = ($null -ne $alt); Wert = $null; Typ = $null }
                    if ($alt) { $e.Wert = $alt.Wert; $e.Typ = $alt.Typ }
                    $bk[$key] = $e
                }
                Speichere-Backup $bk   # erst sichern, dann aendern
                foreach ($r in $t.Reg) {
                    if (-not (Test-Path -Path $r.P)) { New-Item -Path $r.P -Force -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -Path $r.P -Name $r.N -Value $r.V -Type $r.T -ErrorAction Stop
                }
            } else {
                $hatte = $false
                foreach ($r in $t.Reg) {
                    $key = "$($r.P)|$($r.N)"
                    if (-not $bk.ContainsKey($key)) { continue }
                    $b = $bk[$key]
                    if ($b.Da) { Set-ItemProperty -Path $b.P -Name $b.N -Value $b.Wert -Type $b.Typ -ErrorAction Stop }
                    else { Remove-ItemProperty -Path $b.P -Name $b.N -ErrorAction SilentlyContinue }
                    $bk.Remove($key); $hatte = $true
                }
                Speichere-Backup $bk
                if (-not $hatte) { Log "$($t.Name): war schon vor PULS so eingestellt - kein Originalwert gesichert, nichts geändert." 'warn'; return }
            }
        } else {
            if ($an) { & $t.An; $bk["befehl|$($t.Id)"] = [pscustomobject]@{ Key = "befehl|$($t.Id)" } }
            else { & $t.Aus; $bk.Remove("befehl|$($t.Id)") }
            Speichere-Backup $bk
        }
        $was = 'zurückgesetzt'; if ($an) { $was = 'aktiviert' }
        Log "$($t.Name) $was (wirkt $($t.Wirkt))" 'ok'
    } catch { Log "$($t.Name): $($_.Exception.Message)" 'fehler' }
}
function Tweaks-Bauen {
    $l = $ui.TweakListe; $l.Children.Clear()
    $script:TweakRows = New-Object System.Collections.ArrayList
    foreach ($kat in @($kL, $kB, $kW)) {
        [void]$l.Children.Add((T $kat 16 '#FFFFFF' -Fett -m '0,10,0,8'))
        foreach ($t in ($script:Tweaks | Where-Object { $_.Kat -eq $kat })) {
            $b = New-Object Windows.Controls.Border; $b.Background = '#1D1D23'; $b.CornerRadius = '8'; $b.Padding = '14,10'; $b.Margin = '0,0,0,6'
            $g = New-Object Windows.Controls.Grid
            foreach ($w in '*', 'Auto') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
            $sp = New-Object Windows.Controls.StackPanel
            $cb = New-Object Windows.Controls.CheckBox; $cb.Content = $t.Name; $cb.FontSize = 14; $cb.Foreground = '#FFFFFF'; $cb.VerticalContentAlignment = 'Center'
            $desc = $t.Warum
            if ($t.Extra) { try { $x = & $t.Extra; if ($x) { $desc += " $x" } } catch {} }
            $info = "Wirkt $($t.Wirkt)"; if ($t.Empf) { $info += '  ·  empfohlen' }
            [void]$sp.Children.Add($cb)
            [void]$sp.Children.Add((T $desc 12 '#9A9AA8' -m '22,3,0,0'))
            [void]$sp.Children.Add((T $info 11 '#6A6A78' -m '22,2,0,0'))
            $pill = New-Object Windows.Controls.Border; $pill.CornerRadius = '10'; $pill.Padding = '10,3'; $pill.VerticalAlignment = 'Top'; $pill.Margin = '12,0,0,0'
            $pt = T '' 11 '#000000' -Fett; $pill.Child = $pt
            [Windows.Controls.Grid]::SetColumn($pill, 1)
            [void]$g.Children.Add($sp); [void]$g.Children.Add($pill)
            $b.Child = $g
            [void]$l.Children.Add($b)
            [void]$script:TweakRows.Add([pscustomobject]@{ T = $t; Cb = $cb; Pill = $pill; Text = $pt })
        }
    }
    Tweaks-Status
}
function Tweaks-Status {
    foreach ($r in $script:TweakRows) {
        if (Tweak-Ist $r.T) { $r.Pill.Background = '#00D1B2'; $r.Text.Text = 'AKTIV'; $r.Text.Foreground = '#0B0B0E' }
        else { $r.Pill.Background = '#2A2A33'; $r.Text.Text = 'AUS'; $r.Text.Foreground = '#9A9AA8' }
    }
}

# ---------- Bloatware ----------
$script:BloatDef = @(
    @{ M = 'Microsoft.BingNews'; N = 'Microsoft News'; S = $true },
    @{ M = 'Microsoft.BingWeather'; N = 'Wetter'; S = $true },
    @{ M = 'Microsoft.BingSearch'; N = 'Bing-Suche'; S = $true },
    @{ M = 'Microsoft.GetHelp'; N = 'Hilfe anfordern'; S = $true },
    @{ M = 'Microsoft.Getstarted'; N = 'Tipps'; S = $true },
    @{ M = 'Microsoft.MicrosoftSolitaireCollection'; N = 'Solitaire Collection'; S = $true },
    @{ M = 'Microsoft.MicrosoftOfficeHub'; N = 'Microsoft 365 (Office-Hub)'; S = $true },
    @{ M = 'Microsoft.People'; N = 'Kontakte'; S = $true },
    @{ M = 'Microsoft.PowerAutomateDesktop'; N = 'Power Automate'; S = $true },
    @{ M = 'Microsoft.Todos'; N = 'Microsoft To Do'; S = $true },
    @{ M = 'Microsoft.WindowsFeedbackHub'; N = 'Feedback-Hub'; S = $true },
    @{ M = 'Microsoft.WindowsMaps'; N = 'Karten'; S = $true },
    @{ M = 'Microsoft.ZuneVideo'; N = 'Filme & TV'; S = $true },
    @{ M = 'Clipchamp.Clipchamp'; N = 'Clipchamp'; S = $true },
    @{ M = 'Microsoft.549981C3F5F10'; N = 'Cortana'; S = $true },
    @{ M = 'Microsoft.Copilot'; N = 'Copilot-App'; S = $true },
    @{ M = 'MicrosoftTeams'; N = 'Teams (privat, alt)'; S = $true },
    @{ M = 'MSTeams'; N = 'Teams'; S = $false },
    @{ M = 'Microsoft.OutlookForWindows'; N = 'Outlook (neu)'; S = $false },
    @{ M = 'Microsoft.windowscommunicationsapps'; N = 'Mail & Kalender (alt)'; S = $true },
    @{ M = 'Microsoft.MicrosoftJournal'; N = 'Journal'; S = $true },
    @{ M = 'Microsoft.Windows.DevHome'; N = 'Dev Home'; S = $true },
    @{ M = 'MicrosoftCorporationII.MicrosoftFamily'; N = 'Microsoft Family'; S = $true },
    @{ M = 'Microsoft.MixedReality.Portal'; N = 'Mixed Reality-Portal'; S = $true },
    @{ M = 'Microsoft.Microsoft3DViewer'; N = '3D-Viewer'; S = $true },
    @{ M = 'Microsoft.SkypeApp'; N = 'Skype'; S = $true },
    @{ M = 'Microsoft.YourPhone'; N = 'Smartphone-Link'; S = $false },
    @{ M = 'Microsoft.MicrosoftStickyNotes'; N = 'Kurznotizen'; S = $false },
    @{ M = 'king.com.*'; N = 'Candy Crush & Co. (King)'; S = $true },
    @{ M = '*Disney*'; N = 'Disney+'; S = $true },
    @{ M = '*Facebook*'; N = 'Facebook'; S = $true },
    @{ M = '*Instagram*'; N = 'Instagram'; S = $true },
    @{ M = '*TikTok*'; N = 'TikTok'; S = $true },
    @{ M = '*LinkedIn*'; N = 'LinkedIn'; S = $true },
    @{ M = 'AmazonVideo.PrimeVideo'; N = 'Prime Video'; S = $true }
)
$bgBloat = {
    param($muster)
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    foreach ($m in $muster) {
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $m -ErrorAction SilentlyContinue)) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; "OK|$($p.Name)" }
            catch {
                try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; "OK|$($p.Name)" }
                catch { "FEHLER|$($p.Name)|$($_.Exception.Message)" }
            }
        }
        foreach ($pp in @($prov | Where-Object { $_.DisplayName -like $m })) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null; "PROV|$($pp.DisplayName)" } catch {}
        }
    }
}
function Bloat-Laden {
    $l = $ui.BloatListe; $l.Children.Clear()
    $script:BloatRows = New-Object System.Collections.ArrayList
    if ($script:IstAdmin) { $inst = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } else { $inst = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
    foreach ($d in $script:BloatDef) {
        $namen = @($inst | Where-Object { $_.Name -like $d.M } | ForEach-Object { $_.Name } | Select-Object -Unique)
        if (-not $namen.Count) { continue }
        $b = New-Object Windows.Controls.Border; $b.Background = '#1D1D23'; $b.CornerRadius = '8'; $b.Padding = '14,9'; $b.Margin = '0,0,0,6'
        $sp = New-Object Windows.Controls.StackPanel
        $cb = New-Object Windows.Controls.CheckBox; $cb.Content = $d.N; $cb.FontSize = 14; $cb.Foreground = '#FFFFFF'; $cb.IsChecked = $d.S
        [void]$sp.Children.Add($cb)
        [void]$sp.Children.Add((T ($namen -join ', ') 11 '#6A6A78' -m '22,2,0,0'))
        $b.Child = $sp
        [void]$l.Children.Add($b)
        [void]$script:BloatRows.Add([pscustomobject]@{ D = $d; Cb = $cb })
    }
    if (-not $script:BloatRows.Count) { [void]$l.Children.Add((T 'Keine bekannte Bloatware gefunden - sauber!' 14 '#00D1B2')) }
}

# ---------- DNS ----------
$script:DnsServer = @(
    [pscustomobject]@{ Name = 'Cloudflare'; Ip = '1.1.1.1'; Alle = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001') },
    [pscustomobject]@{ Name = 'Google'; Ip = '8.8.8.8'; Alle = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844') },
    [pscustomobject]@{ Name = 'Quad9'; Ip = '9.9.9.9'; Alle = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9') },
    [pscustomobject]@{ Name = 'OpenDNS'; Ip = '208.67.222.222'; Alle = @('208.67.222.222', '208.67.220.220', '2620:119:35::35', '2620:119:53::53') }
)
$bgDns = {
    param($liste)
    $ziele = 'wikipedia.org', 'github.com', 'microsoft.com', 'youtube.com', 'amazon.de', 'cloudflare.com'
    foreach ($s in $liste) {
        $z = New-Object System.Collections.ArrayList; $f = 0
        foreach ($d in $ziele) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { Resolve-DnsName -Name $d -Server $s.Ip -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null; [void]$z.Add($sw.Elapsed.TotalMilliseconds) }
            catch { $f++ }
        }
        $med = -1
        if ($z.Count) { $so = @($z | Sort-Object); $med = $so[[int][math]::Floor(($so.Count - 1) / 2)] }
        [pscustomobject]@{ Name = $s.Name; Ip = $s.Ip; Median = $med; Fehler = $f }
    }
}
function Dns-Adapter {
    foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        # nur echte Netzwerkkarten - VPN-/virtuelle Adapter (Radmin, Hyper-V ...) nicht anfassen
        if ($c.IPv4DefaultGateway -and $c.NetAdapter.Status -eq 'Up' -and $c.NetAdapter.HardwareInterface) {
            [pscustomobject]@{ Index = $c.InterfaceIndex; Alias = $c.InterfaceAlias; Guid = [string]$c.NetAdapter.InterfaceGuid }
        }
    }
}
function Dns-Statisch($guid, [bool]$v6) {
    $basis = 'Tcpip'; if ($v6) { $basis = 'Tcpip6' }
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$basis\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction SilentlyContinue).NameServer
    if ($v) { @($v -split '[,\s]+' | Where-Object { $_ }) } else { @() }
}
function Dns-Anzeigen {
    $txt = foreach ($a in @(Dns-Adapter)) {
        $s = @((Get-DnsClientServerAddress -InterfaceIndex $a.Index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        "$($a.Alias): $($s -join ', ')"
    }
    if (-not $txt) { $txt = 'Kein aktiver Netzwerkadapter gefunden.' }
    $bk = 'nein'; if (Test-Path $script:DnsBackup) { $bk = 'ja - "Original wiederherstellen" setzt alles zurück' }
    $ui.DnsAktuell.Text = "Aktuell: $($txt -join '   |   ')`nPULS-Backup vorhanden: $bk"
}
function Dns-Zurueck {
    try {
        if (-not (Test-Path $script:DnsBackup)) {
            foreach ($a in @(Dns-Adapter)) { Set-DnsClientServerAddress -InterfaceIndex $a.Index -ResetServerAddresses -ErrorAction Stop }
            Log 'Kein PULS-Backup vorhanden - Adapter auf automatisch (vom Router) gesetzt.' 'ok'
        } else {
            foreach ($e in @(Get-Content $script:DnsBackup -Raw | ConvertFrom-Json)) {
                $ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $e.Guid } | Select-Object -First 1
                if (-not $ad) { continue }
                Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction Stop
                $alle = @(@($e.V4) + @($e.V6) | Where-Object { $_ })
                if ($alle.Count) { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $alle -ErrorAction Stop }
            }
            Remove-Item $script:DnsBackup -Force
            Log 'Original-DNS wiederhergestellt.' 'ok'
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } catch { Log "DNS zurücksetzen fehlgeschlagen: $($_.Exception.Message)" 'fehler' }
    Dns-Anzeigen
}
function Dns-Setzen($s) {
    $script:DnsZiel = $s
    Mit-Restorepunkt "DNS auf $($s.Name)" {
        $s = $script:DnsZiel
        $ad = @(Dns-Adapter)
        if (-not $ad.Count) { Log 'Kein aktiver Netzwerkadapter gefunden.' 'fehler'; return }
        if (-not (Test-Path $script:DnsBackup)) {
            if (-not (Test-Path $script:Ablage)) { New-Item -ItemType Directory -Path $script:Ablage -Force | Out-Null }
            $bk = foreach ($a in $ad) { [pscustomobject]@{ Guid = $a.Guid; Alias = $a.Alias; V4 = @(Dns-Statisch $a.Guid $false); V6 = @(Dns-Statisch $a.Guid $true) } }
            ConvertTo-Json -InputObject @($bk) -Depth 4 | Set-Content $script:DnsBackup -Encoding UTF8
            Log 'Bisherige DNS-Einstellung gesichert.' 'ok'
        }
        try {
            foreach ($a in $ad) {
                try { Set-DnsClientServerAddress -InterfaceIndex $a.Index -ServerAddresses $s.Alle -ErrorAction Stop }
                catch { Set-DnsClientServerAddress -InterfaceIndex $a.Index -ServerAddresses @($s.Alle | Where-Object { $_ -notmatch ':' }) -ErrorAction Stop }
            }
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
            Resolve-DnsName 'microsoft.com' -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null
            Resolve-DnsName 'wikipedia.org' -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null
            Log "DNS auf $($s.Name) umgestellt und getestet - Internet funktioniert." 'ok'
        } catch {
            Log "Test nach dem Umstellen fehlgeschlagen ($($_.Exception.Message)) - stelle Original automatisch wieder her." 'fehler'
            Dns-Zurueck
        }
        Dns-Anzeigen
    }
}
function Dns-Test {
    $ui.BtnDnsTest.IsEnabled = $false
    $ui.DnsListe.Children.Clear()
    [void]$ui.DnsListe.Children.Add((T 'Messe ... (ca. 5-15 Sekunden)' 14 '#9A9AA8'))
    $liste = New-Object System.Collections.ArrayList
    $ad = @(Dns-Adapter) | Select-Object -First 1
    if ($ad) {
        $akt = @((Get-DnsClientServerAddress -InterfaceIndex $ad.Index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) | Select-Object -First 1
        if ($akt) { [void]$liste.Add([pscustomobject]@{ Name = 'Aktuell'; Ip = $akt }) }
    }
    foreach ($s in $script:DnsServer) { [void]$liste.Add($s) }
    Start-Bg $bgDns @(, @($liste)) {
        param($res)
        $ui.BtnDnsTest.IsEnabled = $true
        $l = $ui.DnsListe; $l.Children.Clear()
        $ok = @($res | Where-Object { $_.Median -ge 0 } | Sort-Object Median)
        if (-not $ok.Count) { [void]$l.Children.Add((T 'Kein DNS-Server erreichbar (offline oder Firewall blockt Port 53).' 14 '#FF5C5C')); return }
        $max = [double]($ok | Measure-Object Median -Maximum).Maximum
        $k = Karte 'Ergebnis (Median aus 6 Abfragen, kleiner = besser)'
        foreach ($e in @($ok) + @($res | Where-Object { $_.Median -lt 0 })) {
            $g = New-Object Windows.Controls.Grid; $g.Margin = '0,4'
            foreach ($w in '130', '150', '*', '110', '130') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
            $farbe = '#9A9AA8'; if ($e -eq $ok[0]) { $farbe = '#00D1B2' }
            $n = T $e.Name 13 '#FFFFFF' -Fett; $n.VerticalAlignment = 'Center'
            $ip = T $e.Ip 12 '#9A9AA8'; $ip.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($ip, 1)
            if ($e.Median -ge 0) { $bar = Balken ($e.Median / $max * 100) $farbe; $ms = T ('{0:N0} ms' -f $e.Median) 13 $farbe -Fett }
            else { $bar = Balken 0 '#FF5C5C'; $ms = T 'nicht erreichbar' 12 '#FF5C5C' }
            $bar.Margin = '0,0,12,0'; [Windows.Controls.Grid]::SetColumn($bar, 2)
            $ms.VerticalAlignment = 'Center'; $ms.TextAlignment = 'Right'; [Windows.Controls.Grid]::SetColumn($ms, 3)
            [void]$g.Children.Add($n); [void]$g.Children.Add($ip); [void]$g.Children.Add($bar); [void]$g.Children.Add($ms)
            $srv = $script:DnsServer | Where-Object { $_.Ip -eq $e.Ip } | Select-Object -First 1
            if ($srv -and $e.Median -ge 0 -and $e.Name -ne 'Aktuell') {
                $btn = New-Object Windows.Controls.Button; $btn.Content = 'Übernehmen'; $btn.Margin = '12,0,0,0'; $btn.Padding = '10,4'; $btn.Tag = $srv
                if ($e -eq $ok[0]) { $btn.Style = $fenster.FindResource('Akzent') }
                $btn.Add_Click({ Dns-Setzen $this.Tag })
                [Windows.Controls.Grid]::SetColumn($btn, 4); [void]$g.Children.Add($btn)
            }
            [void]$k.Child.Children.Add($g)
        }
        [void]$k.Child.Children.Add((T 'Unter ~10 ms Unterschied merkt man nicht. Der Router-DNS ("Aktuell") ist oft schnell, weil er Antworten zwischenspeichert.' 12 '#6A6A78' -m '0,10,0,0'))
        [void]$l.Children.Add($k)
    }
}

# ---------- Speicherplatz ----------
function Zeige-Platz($n) {
    $script:PlatzNode = $n
    $ui.PlatzPfad.Text = $n.Path
    $l = $ui.PlatzListe; $l.Children.Clear()
    $ges = [double]$n.Size; if ($ges -le 0) { $ges = 1 }
    $ui.PlatzStatus.Text = '{0} gesamt  ·  {1} Unterordner  ·  {2} in Dateien direkt hier  ·  Klick auf einen Ordner = hineingehen' -f (Fmt $n.Size), $n.Kids.Count, (Fmt $n.Files)
    foreach ($k in @($n.Kids | Sort-Object Size -Descending | Select-Object -First 60)) {
        $pct = $k.Size / $ges * 100
        $b = New-Object Windows.Controls.Border
        $b.Child = Zeile $k.Name $pct ('{0}    {1,3:N0} %' -f (Fmt $k.Size), $pct) (Farbe-Pct ($pct * 1.5)) 300
        $b.Padding = '10,4'; $b.CornerRadius = '6'; $b.Background = '#00000000'; $b.Cursor = 'Hand'; $b.Tag = $k; $b.ToolTip = $k.Path
        $b.Add_MouseEnter({ $this.Background = '#1D1D23' })
        $b.Add_MouseLeave({ $this.Background = '#00000000' })
        $b.Add_MouseLeftButtonUp({ if ($this.Tag.Kids.Count) { Zeige-Platz $this.Tag } })
        [void]$l.Children.Add($b)
    }
}
function Platz-Scan([string]$pfad) {
    if ($script:Scannt) { return }
    if (-not $pfad -or -not (Test-Path -LiteralPath $pfad -PathType Container)) { Log "Ordner nicht gefunden: $pfad" 'fehler'; return }
    $script:Scannt = $true
    $ui.BtnPlatzScan.IsEnabled = $false
    $ui.PlatzListe.Children.Clear()
    $script:ScanStart = Get-Date
    Start-Bg { param($p) [PulsScan]::Scan($p) } @((Resolve-Path -LiteralPath $pfad).Path) {
        param($res)
        $script:Scannt = $false; $ui.BtnPlatzScan.IsEnabled = $true
        $n = @($res)[0]
        if (-not $n) { Log 'Scan fehlgeschlagen.' 'fehler'; return }
        Log ('Speicher-Scan fertig: {0:N0} Ordner in {1:N1} s' -f [PulsScan]::Ordner, ((Get-Date) - $script:ScanStart).TotalSeconds) 'ok'
        Zeige-Platz $n
    }
}

# ---------- Uebersicht ----------
function Uebersicht-Laden {
    $l = $ui.UebersichtListe; $l.Children.Clear()
    $os = Get-CimInstance Win32_OperatingSystem
    $cpuInfo = @(Get-CimInstance Win32_Processor)
    $cpu = [double]($cpuInfo | Measure-Object LoadPercentage -Average).Average
    $ramGes = [double]$os.TotalVisibleMemorySize * 1KB
    $ramPct = 100 - ($os.FreePhysicalMemory * 1KB / $ramGes * 100)
    $commitPct = 100 - ($os.FreeVirtualMemory / $os.TotalVirtualMemorySize * 100)
    $score = 100; $funde = New-Object System.Collections.ArrayList
    if ($cpu -ge 85) { $score -= 15; [void]$funde.Add('CPU dauerhaft hoch - "Ressourcenfresser messen" zeigt den Verursacher.') }
    if ($ramPct -ge 85) { $score -= 20; [void]$funde.Add('RAM fast voll - "Ressourcenfresser messen" zeigt, wer ihn belegt.') }
    if ($commitPct -ge 85) { $score -= 15; [void]$funde.Add('Commit-Limit fast erreicht: Programme können abstürzen. Auslagerungsdatei nicht verkleinern.') }
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size })
    foreach ($d in $disks) {
        if ((100 - $d.FreeSpace / $d.Size * 100) -ge 90) { $score -= 15; [void]$funde.Add("Laufwerk $($d.DeviceID) über 90 % voll - SSDs werden langsamer, Updates scheitern. Siehe Tab Speicherplatz.") }
    }
    $up = (Get-Date) - $os.LastBootUpTime
    $hiber = (Reg-Lesen 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled').Wert
    if ($up.TotalDays -ge 4) {
        $score -= 10; $t = 'Seit über 4 Tagen kein echter Neustart.'
        if ($hiber -eq 1) { $t += ' Schnellstart ist an: "Herunterfahren" startet den Kernel nicht neu (Tweak "Schnellstart aus").' }
        [void]$funde.Add($t)
    }
    $plan = (powercfg /getactivescheme) -join ' '
    if ($plan -match '\((.+)\)') { $plan = $Matches[1] }
    if ($plan -match 'sparmodus|Power saver') { $score -= 10; [void]$funde.Add('Energiesparplan aktiv: CPU wird gedrosselt.') }
    if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        $score -= 10; [void]$funde.Add('Ein Update wartet auf Neustart - bis dahin laufen oft Hintergrund-Installer.')
    }
    $score = [math]::Max(0, $score)

    # Score-Karte
    $k = Karte ''
    $g = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto', '*') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
    $zahl = T "$score" 56 (Farbe-Pct (100 - $score)) -Fett -m '0,-8,24,0'
    $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$sp.Children.Add((T 'PULS-Score' 18 '#FFFFFF' -Fett))
    $sub = 'Keine Auffälligkeiten - dein System läuft sauber.'; if ($funde.Count) { $sub = "$($funde.Count) Befund(e) - siehe unten." }
    [void]$sp.Children.Add((T $sub 13 '#9A9AA8'))
    [void]$g.Children.Add($zahl); [void]$g.Children.Add($sp)
    [void]$k.Child.Children.Add($g)
    [void]$l.Children.Add($k)

    $k = Karte 'Auslastung'
    [void]$k.Child.Children.Add((Zeile 'CPU' $cpu ('{0:N0} %' -f $cpu) (Farbe-Pct $cpu) 150))
    [void]$k.Child.Children.Add((Zeile 'Arbeitsspeicher' $ramPct ('{0:N0} %  ({1} / {2})' -f $ramPct, (Fmt ($ramGes * $ramPct / 100)), (Fmt $ramGes)) (Farbe-Pct $ramPct) 150))
    [void]$k.Child.Children.Add((Zeile 'Commit (RAM+Swap)' $commitPct ('{0:N0} %' -f $commitPct) (Farbe-Pct $commitPct) 150))
    foreach ($d in $disks) {
        $p = 100 - ($d.FreeSpace / $d.Size * 100)
        [void]$k.Child.Children.Add((Zeile "Laufwerk $($d.DeviceID)" $p ('{0:N0} %  ({1} frei)' -f $p, (Fmt $d.FreeSpace)) (Farbe-Pct $p) 150))
    }
    [void]$l.Children.Add($k)

    $k = Karte 'System'
    $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $osName = $os.Caption -replace '^Microsoft ', ''
    $gpus = (@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join ', '
    foreach ($z in @(
            @('Windows', "$osName $($ver.DisplayVersion) (Build $($ver.CurrentBuild))"),
            @('Prozessor', ($cpuInfo[0].Name.Trim() + "  ·  $([Environment]::ProcessorCount) Threads")),
            @('Grafik', $gpus),
            @('Laufzeit', ('{0} Tage {1} Std seit echtem Neustart' -f $up.Days, $up.Hours)),
            @('Energieplan', $plan),
            @('Adminrechte', $(if ($script:IstAdmin) { 'ja' } else { 'nein - Tweaks gesperrt' })))) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '0,2'
        foreach ($w in '150', '*') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $a = T $z[0] 13 '#9A9AA8'; $b = T $z[1]; [Windows.Controls.Grid]::SetColumn($b, 1)
        [void]$g.Children.Add($a); [void]$g.Children.Add($b)
        [void]$k.Child.Children.Add($g)
    }
    [void]$l.Children.Add($k)

    if ($funde.Count) {
        $k = Karte 'Befunde'
        foreach ($f in $funde) { [void]$k.Child.Children.Add((T "•  $f" 13 '#FFB547' -m '0,2')) }
        [void]$l.Children.Add($k)
    }
}
$bgHogs = {
    $v = @{}
    foreach ($p in Get-Process) { try { $v[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {} }
    Start-Sleep -Seconds 2
    $kerne = [Environment]::ProcessorCount; $g = @{}
    foreach ($p in Get-Process) {
        $d = 0
        try { if ($v.ContainsKey($p.Id)) { $d = $p.TotalProcessorTime.TotalMilliseconds - $v[$p.Id] } } catch {}
        if (-not $g.ContainsKey($p.ProcessName)) { $g[$p.ProcessName] = [pscustomobject]@{ Name = $p.ProcessName; Cpu = 0.0; Ram = 0.0; Anz = 0 } }
        $x = $g[$p.ProcessName]; $x.Cpu += [math]::Max(0, $d) / (2000 * $kerne) * 100; $x.Ram += $p.WorkingSet64; $x.Anz++
    }
    $g.Values
}
function Hogs-Start {
    $ui.BtnHogs.IsEnabled = $false
    $ui.HogsListe.Children.Clear()
    [void]$ui.HogsListe.Children.Add((T 'Messe 2 Sekunden ...' 14 '#9A9AA8'))
    Start-Bg $bgHogs @() {
        param($res)
        $ui.BtnHogs.IsEnabled = $true
        $l = $ui.HogsListe; $l.Children.Clear()
        $ramGes = [double](Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize * 1KB
        $k = Karte 'CPU - Top 8 Programme (alle Prozesse eines Programms zusammengezählt)'
        foreach ($x in @($res | Sort-Object Cpu -Descending | Select-Object -First 8)) {
            [void]$k.Child.Children.Add((Zeile $x.Name $x.Cpu ('{0:N1} %   ×{1}' -f $x.Cpu, $x.Anz) (Farbe-Pct ($x.Cpu * 2))))
        }
        [void]$l.Children.Add($k)
        $k = Karte 'Arbeitsspeicher - Top 8'
        foreach ($x in @($res | Sort-Object Ram -Descending | Select-Object -First 8)) {
            $p = $x.Ram / $ramGes * 100
            [void]$k.Child.Children.Add((Zeile $x.Name ($p * 2) ('{0}   ×{1}' -f (Fmt $x.Ram), $x.Anz) (Farbe-Pct ($p * 3))))
        }
        [void]$l.Children.Add($k)
    }
}

# ---------- Analyse ----------
$bgAnalyse = {
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    function D($ev) { $h = @{}; foreach ($n in ([xml]$ev.ToXml()).Event.EventData.Data) { $h[$n.Name] = $n.'#text' }; $h }
    $boot = @(); $brems = @(); $fehlerBoot = ''
    try {
        $boot = foreach ($b in Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 100 } -MaxEvents 10 -ErrorAction Stop) {
            $d = D $b
            [pscustomobject]@{ Zeit = $b.TimeCreated; Ges = [double]$d['BootTime'] / 1000; Kern = [double]$d['MainPathBootTime'] / 1000; Nach = [double]$d['BootPostBootTime'] / 1000 }
        }
    } catch { $fehlerBoot = $_.Exception.Message }
    try {
        $g = foreach ($b in Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 101, 102, 103, 106, 109 } -MaxEvents 80 -ErrorAction Stop) {
            $d = D $b; $n = $d['FriendlyName']; if (-not $n) { $n = $d['Name'] }
            if ($n) { [pscustomobject]@{ Name = $n; Verz = [double]$d['DegradationTime'] } }
        }
        $brems = foreach ($x in ($g | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 8)) {
            [pscustomobject]@{ Name = $x.Name; Anz = $x.Count; Sek = ($x.Group | Measure-Object Verz -Average).Average / 1000 }
        }
    } catch {}
    $dienste = foreach ($s in Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State='Running'") {
        if ($s.PathName -notmatch '^\s*"?(.+?\.exe)') { continue }
        $exe = $Matches[1]; $firma = ''
        try { $firma = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).CompanyName } catch {}
        if ($firma -match 'Microsoft') { continue }
        $ram = 0; try { $ram = (Get-Process -Id $s.ProcessId -ErrorAction Stop).WorkingSet64 } catch {}
        if (-not $firma) { $firma = '(unbekannt)' }
        [pscustomobject]@{ Name = $s.DisplayName; Firma = $firma; Ram = [double]$ram }
    }
    $disks = foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $r = $null; try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        [pscustomobject]@{ Name = [string]$d.FriendlyName; Typ = [string]$d.MediaType; Size = [double]$d.Size; Status = [string]$d.HealthStatus
            Temp = $r.Temperature; Wear = $r.Wear; Std = $r.PowerOnHours; Fehler = $r.ReadErrorsUncorrected }
    }
    [pscustomobject]@{ Boot = @($boot); FehlerBoot = $fehlerBoot; Bremsen = @($brems); Dienste = @($dienste | Sort-Object Ram -Descending); Disks = @($disks) }
}
function Analyse-Start {
    $ui.BtnAnalyse.IsEnabled = $false
    $ui.AnalyseListe.Children.Clear()
    [void]$ui.AnalyseListe.Children.Add((T 'Analysiere ... (einige Sekunden)' 14 '#9A9AA8'))
    Start-Bg $bgAnalyse @() {
        param($res)
        $ui.BtnAnalyse.IsEnabled = $true
        $l = $ui.AnalyseListe; $l.Children.Clear()
        $a = @($res)[0]
        if (-not $a) { [void]$l.Children.Add((T 'Analyse fehlgeschlagen.' 14 '#FF5C5C')); return }

        $k = Karte 'Laufwerke'
        foreach ($d in $a.Disks) {
            $farbe = '#00D1B2'; if ($d.Status -ne 'Healthy') { $farbe = '#FF5C5C' }
            [void]$k.Child.Children.Add((T ('{0}   ·   {1}   ·   {2}   ·   Status: {3}' -f $d.Name, $d.Typ, (Fmt $d.Size), $d.Status) 13 $farbe -Fett))
            $teile = @()
            if ($d.Temp) { $teile += "Temperatur $($d.Temp) °C" }
            if ($null -ne $d.Wear) { $teile += "Abnutzung $($d.Wear) %" }
            if ($null -ne $d.Std) { $teile += "Betriebsstunden $($d.Std)" }
            if ($d.Fehler) { $teile += "UNKORRIGIERTE LESEFEHLER: $($d.Fehler)" }
            if (-not $teile) { $teile = @('Keine SMART-Details verfügbar (Adminrechte nötig oder vom Treiber nicht geliefert).') }
            [void]$k.Child.Children.Add((T ($teile -join '   ·   ') 12 '#9A9AA8' -m '0,2,0,8'))
            if ($d.Temp -ge 70) { [void]$k.Child.Children.Add((T 'Sehr heiß - SSDs drosseln ab ca. 70 °C.' 12 '#FFB547')) }
            if ($d.Wear -ge 80) { [void]$k.Child.Children.Add((T 'Stark abgenutzt - Backup machen und Ersatz einplanen.' 12 '#FFB547')) }
        }
        [void]$l.Children.Add($k)

        $k = Karte 'Bootzeiten (letzte Starts)'
        if ($a.Boot.Count) {
            $max = [double]($a.Boot | Measure-Object Ges -Maximum).Maximum; if ($max -le 0) { $max = 1 }
            foreach ($b in $a.Boot) {
                [void]$k.Child.Children.Add((Zeile ('{0:dd.MM.yy  HH:mm}' -f $b.Zeit) ($b.Ges / $max * 100) ('{0:N0} s  (Desktop nach {1:N0} s)' -f $b.Ges, $b.Kern) (Farbe-Pct ($b.Ges / 90 * 100)) 150))
            }
        } else { [void]$k.Child.Children.Add((T "Keine Daten. $($a.FehlerBoot)" 12 '#9A9AA8')) }
        [void]$l.Children.Add($k)

        if ($a.Bremsen.Count) {
            $k = Karte 'Von Windows gemeldete Boot-Bremsen'
            foreach ($b in $a.Bremsen) { [void]$k.Child.Children.Add((T ('{0}   -   {1}× gemeldet, ~{2:N1} s Verzögerung' -f $b.Name, $b.Anz, $b.Sek) 13 '#FFB547' -m '0,2')) }
            [void]$l.Children.Add($k)
        }

        $k = Karte 'Fremddienste (starten automatisch, nicht von Microsoft)'
        foreach ($s in $a.Dienste) {
            $g = New-Object Windows.Controls.Grid; $g.Margin = '0,2'
            foreach ($w in '*', '240', '100') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
            $x1 = T $s.Name; $x2 = T $s.Firma 12 '#9A9AA8'; $x3 = T (Fmt $s.Ram) 12 '#B8B8C4'; $x3.TextAlignment = 'Right'
            [Windows.Controls.Grid]::SetColumn($x2, 1); [Windows.Controls.Grid]::SetColumn($x3, 2)
            [void]$g.Children.Add($x1); [void]$g.Children.Add($x2); [void]$g.Children.Add($x3)
            [void]$k.Child.Children.Add($g)
        }
        if (-not $a.Dienste.Count) { [void]$k.Child.Children.Add((T 'Keine.' 13 '#00D1B2')) }
        [void]$k.Child.Children.Add((T 'Nur Anzeige. Updater-/Launcher-Dienste kann man in services.msc auf "Manuell" stellen; Treiber- und Virenschutz-Dienste in Ruhe lassen.' 12 '#6A6A78' -m '0,8,0,0'))
        [void]$l.Children.Add($k)
    }
}

# ---------- Oberflaeche ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PULS - PC-Tuning" Width="1120" Height="760" MinWidth="920" MinHeight="600"
        Background="#141418" Foreground="#E6E6EA" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A33"/>
      <Setter Property="Foreground" Value="#E6E6EA"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Akzent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#00B39A"/>
      <Setter Property="Foreground" Value="#0B0B0E"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B8B8C4"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="Transparent" Padding="18,10" Margin="10,1" CornerRadius="6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1C1C22"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#23232B"/>
                <Setter Property="Foreground" Value="#00D1B2"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="24"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A8A98"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Margin" Value="0,4,0,12"/>
    </Style>
  </Window.Resources>
  <Grid Background="#141418">
    <Grid.ColumnDefinitions><ColumnDefinition Width="210"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <DockPanel Background="#0F0F12">
      <StackPanel DockPanel.Dock="Top" Margin="0,22,0,0">
        <TextBlock Text="PULS" FontSize="32" FontWeight="Bold" Foreground="#00D1B2" Margin="28,0,0,0"/>
        <TextBlock Text="PC-Tuning" Foreground="#6A6A78" Margin="30,0,0,26"/>
        <RadioButton x:Name="NavUebersicht" Style="{StaticResource Nav}" Content="Übersicht" IsChecked="True"/>
        <RadioButton x:Name="NavTweaks" Style="{StaticResource Nav}" Content="Tweaks"/>
        <RadioButton x:Name="NavBloat" Style="{StaticResource Nav}" Content="Bloatware"/>
        <RadioButton x:Name="NavDns" Style="{StaticResource Nav}" Content="DNS"/>
        <RadioButton x:Name="NavPlatz" Style="{StaticResource Nav}" Content="Speicherplatz"/>
        <RadioButton x:Name="NavAnalyse" Style="{StaticResource Nav}" Content="Analyse"/>
      </StackPanel>
      <TextBlock x:Name="AdminInfo" DockPanel.Dock="Bottom" VerticalAlignment="Bottom" Foreground="#5A5A66" FontSize="11" Margin="28,0,0,16" TextWrapping="Wrap"/>
    </DockPanel>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="130"/></Grid.RowDefinitions>
      <Grid Margin="28,22,16,8">

        <DockPanel x:Name="SeiteUebersicht">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Übersicht" Style="{StaticResource H1}"/>
            <TextBlock Text="Zustand deines PCs auf einen Blick." Style="{StaticResource Sub}"/>
            <WrapPanel>
              <Button x:Name="BtnUeNeu" Content="Aktualisieren"/>
              <Button x:Name="BtnHogs" Content="Ressourcenfresser messen" Style="{StaticResource Akzent}"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,6,0,0">
            <StackPanel Margin="0,0,12,0"><StackPanel x:Name="UebersichtListe"/><StackPanel x:Name="HogsListe"/></StackPanel>
          </ScrollViewer>
        </DockPanel>

        <DockPanel x:Name="SeiteTweaks" Visibility="Collapsed">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Tweaks" Style="{StaticResource H1}"/>
            <TextBlock Text="Auswählen und anwenden. Vorher wird automatisch ein Wiederherstellungspunkt erstellt und jeder Originalwert gesichert - &quot;Rückgängig&quot; stellt genau den alten Zustand wieder her." Style="{StaticResource Sub}"/>
            <WrapPanel>
              <Button x:Name="BtnTweakEmpf" Content="Empfohlene auswählen"/>
              <Button x:Name="BtnTweakKeine" Content="Auswahl leeren"/>
              <Button x:Name="BtnTweakAn" Content="Ausgewählte anwenden" Style="{StaticResource Akzent}"/>
              <Button x:Name="BtnTweakAus" Content="Ausgewählte rückgängig"/>
              <Button x:Name="BtnExplorer" Content="Explorer neu starten"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,6,0,0"><StackPanel x:Name="TweakListe" Margin="0,0,12,0"/></ScrollViewer>
        </DockPanel>

        <DockPanel x:Name="SeiteBloat" Visibility="Collapsed">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Bloatware" Style="{StaticResource H1}"/>
            <TextBlock Text="Vorinstallierte Apps, die bei dir gefunden wurden. Entfernt wird für alle Benutzer, inklusive Neuinstallations-Sperre bei neuen Konten. Zurückholen geht jederzeit über den Microsoft Store. Xbox-, Store- und System-Apps stehen absichtlich nicht auf der Liste." Style="{StaticResource Sub}"/>
            <WrapPanel>
              <Button x:Name="BtnBloatAlle" Content="Alle auswählen"/>
              <Button x:Name="BtnBloatKeine" Content="Keine"/>
              <Button x:Name="BtnBloatEntfernen" Content="Ausgewählte entfernen" Style="{StaticResource Akzent}"/>
              <Button x:Name="BtnBloatNeu" Content="Neu laden"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,6,0,0"><StackPanel x:Name="BloatListe" Margin="0,0,12,0"/></ScrollViewer>
        </DockPanel>

        <DockPanel x:Name="SeiteDns" Visibility="Collapsed">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="DNS" Style="{StaticResource H1}"/>
            <TextBlock Text="Misst, welcher DNS-Server bei dir am schnellsten antwortet. Beim Übernehmen: erst Wiederherstellungspunkt, dann alte Einstellung sichern, umstellen und sofort testen - klappt der Test nicht, wird automatisch zurückgestellt." Style="{StaticResource Sub}"/>
            <WrapPanel>
              <Button x:Name="BtnDnsTest" Content="Benchmark starten" Style="{StaticResource Akzent}"/>
              <Button x:Name="BtnDnsReset" Content="Original wiederherstellen"/>
            </WrapPanel>
            <TextBlock x:Name="DnsAktuell" Style="{StaticResource Sub}"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="DnsListe" Margin="0,0,12,0"/></ScrollViewer>
        </DockPanel>

        <DockPanel x:Name="SeitePlatz" Visibility="Collapsed">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Speicherplatz" Style="{StaticResource H1}"/>
            <TextBlock Text="Ein paralleler Scan, danach ist das Durchklicken sofort da - kein erneutes Messen pro Ordner." Style="{StaticResource Sub}"/>
            <WrapPanel>
              <TextBox x:Name="PlatzPfad" Width="380" Margin="0,0,8,8" Padding="8,6" Background="#1D1D23" Foreground="#FFFFFF" BorderBrush="#2A2A33" CaretBrush="#FFFFFF" VerticalContentAlignment="Center"/>
              <Button x:Name="BtnPlatzScan" Content="Scannen" Style="{StaticResource Akzent}"/>
              <Button x:Name="BtnPlatzHoch" Content="Eine Ebene hoch"/>
              <Button x:Name="BtnPlatzExplorer" Content="Im Explorer öffnen"/>
            </WrapPanel>
            <TextBlock x:Name="PlatzStatus" Style="{StaticResource Sub}"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PlatzListe" Margin="0,0,12,0"/></ScrollViewer>
        </DockPanel>

        <DockPanel x:Name="SeiteAnalyse" Visibility="Collapsed">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Text="Analyse" Style="{StaticResource H1}"/>
            <TextBlock Text="Laufwerks-Gesundheit, Bootzeiten, Boot-Bremsen und Fremddienste. Nur Anzeige, ändert nichts." Style="{StaticResource Sub}"/>
            <WrapPanel><Button x:Name="BtnAnalyse" Content="Analyse starten" Style="{StaticResource Akzent}"/></WrapPanel>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,6,0,0"><StackPanel x:Name="AnalyseListe" Margin="0,0,12,0"/></ScrollViewer>
        </DockPanel>

      </Grid>
      <Border Grid.Row="1" Background="#0F0F12" Padding="16,8">
        <TextBox x:Name="Log" IsReadOnly="True" Background="Transparent" Foreground="#8A8A98" BorderThickness="0"
                 FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
      </Border>
    </Grid>
  </Grid>
</Window>
'@
$fenster = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name -and $name -ne 'bd') { $ui[$name] = $fenster.FindName($name) }
}

# ---------- Navigation ----------
$script:Seiten = 'Uebersicht', 'Tweaks', 'Bloat', 'Dns', 'Platz', 'Analyse'
foreach ($s in $script:Seiten) {
    $ui["Nav$s"].Tag = $s
    $ui["Nav$s"].Add_Checked({
        foreach ($x in $script:Seiten) { $ui["Seite$x"].Visibility = 'Collapsed' }
        $ui["Seite$($this.Tag)"].Visibility = 'Visible'
    })
}

# ---------- Knoepfe ----------
$ui.BtnUeNeu.Add_Click({ Uebersicht-Laden })
$ui.BtnHogs.Add_Click({ Hogs-Start })

$ui.BtnTweakEmpf.Add_Click({ foreach ($r in $script:TweakRows) { $r.Cb.IsChecked = ($r.T.Empf -and -not (Tweak-Ist $r.T)) } })
$ui.BtnTweakKeine.Add_Click({ foreach ($r in $script:TweakRows) { $r.Cb.IsChecked = $false } })
$ui.BtnTweakAn.Add_Click({
    $script:TweakWahl = @($script:TweakRows | Where-Object { $_.Cb.IsChecked -and -not (Tweak-Ist $_.T) })
    if (-not $script:TweakWahl.Count) { Log 'Nichts zu tun - keine Tweaks ausgewählt oder alle ausgewählten sind schon aktiv.' 'warn'; return }
    Mit-Restorepunkt "$($script:TweakWahl.Count) Tweak(s) anwenden" {
        $bk = Lade-Backup
        foreach ($r in $script:TweakWahl) { Tweak-Setzen $r.T $true $bk; $r.Cb.IsChecked = $false }
        Tweaks-Status
        Log 'Fertig. Einige Tweaks wirken erst nach Abmelden/Neustart (steht beim Tweak).' 'ok'
    }
})
$ui.BtnTweakAus.Add_Click({
    $bk = Lade-Backup
    $script:TweakWahl = @($script:TweakRows | Where-Object { $_.Cb.IsChecked -and (Tweak-Ist $_.T) })
    if (-not $script:TweakWahl.Count) { Log 'Nichts zu tun - keine aktiven Tweaks ausgewählt.' 'warn'; return }
    Mit-Restorepunkt "$($script:TweakWahl.Count) Tweak(s) rückgängig" {
        $bk = Lade-Backup
        foreach ($r in $script:TweakWahl) { Tweak-Setzen $r.T $false $bk; $r.Cb.IsChecked = $false }
        Tweaks-Status
    }
})
$ui.BtnExplorer.Add_Click({
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Log 'Explorer neu gestartet.' 'ok'
})

$ui.BtnBloatAlle.Add_Click({ foreach ($r in $script:BloatRows) { $r.Cb.IsChecked = $true } })
$ui.BtnBloatKeine.Add_Click({ foreach ($r in $script:BloatRows) { $r.Cb.IsChecked = $false } })
$ui.BtnBloatNeu.Add_Click({ Bloat-Laden })
$ui.BtnBloatEntfernen.Add_Click({
    if ($script:Busy) { Log 'Es läuft noch eine Aktion - kurz warten.' 'warn'; return }
    $wahl = @($script:BloatRows | Where-Object { $_.Cb.IsChecked })
    if (-not $wahl.Count) { Log 'Keine Apps ausgewählt.' 'warn'; return }
    $liste = ($wahl | ForEach-Object { "  - $($_.D.N)" }) -join "`n"
    $a = [Windows.MessageBox]::Show("Diese Apps werden für alle Benutzer entfernt:`n`n$liste`n`nZurückholen geht über den Microsoft Store. Fortfahren?", 'PULS', 'YesNo', 'Question')
    if ($a -ne 'Yes') { return }
    $script:BloatMuster = @($wahl | ForEach-Object { $_.D.M })
    Mit-Restorepunkt 'Bloatware entfernen' {
        Set-Busy $true
        Log "Entferne $($script:BloatMuster.Count) App(s) ..."
        Start-Bg $bgBloat @(, $script:BloatMuster) {
            param($res)
            foreach ($z in @($res)) {
                $t = ([string]$z).Split('|')
                switch ($t[0]) {
                    'OK' { Log "Entfernt: $($t[1])" 'ok' }
                    'PROV' { Log "Kommt bei neuen Benutzerkonten nicht wieder: $($t[1])" 'ok' }
                    default { Log "Fehler bei $($t[1]): $($t[2])" 'fehler' }
                }
            }
            Set-Busy $false
            Bloat-Laden
        }
    }
})

$ui.BtnDnsTest.Add_Click({ Dns-Test })
$ui.BtnDnsReset.Add_Click({ if ($script:Busy) { Log 'Es läuft noch eine Aktion - kurz warten.' 'warn'; return }; Dns-Zurueck })

$ui.PlatzPfad.Text = $env:USERPROFILE
$ui.BtnPlatzScan.Add_Click({ Platz-Scan $ui.PlatzPfad.Text })
$ui.PlatzPfad.Add_KeyDown({ if ($_.Key -eq 'Return') { Platz-Scan $ui.PlatzPfad.Text } })
$ui.BtnPlatzHoch.Add_Click({
    if ($script:PlatzNode -and $script:PlatzNode.Parent) { Zeige-Platz $script:PlatzNode.Parent; return }
    $eltern = Split-Path $ui.PlatzPfad.Text -Parent
    if ($eltern) { $ui.PlatzPfad.Text = $eltern; Platz-Scan $eltern }
})
$ui.BtnPlatzExplorer.Add_Click({ if (Test-Path -LiteralPath $ui.PlatzPfad.Text) { Start-Process explorer.exe -ArgumentList "`"$($ui.PlatzPfad.Text)`"" } })

$ui.BtnAnalyse.Add_Click({ Analyse-Start })

# ---------- Hintergrund-Takt ----------
$script:Takt = New-Object Windows.Threading.DispatcherTimer
$script:Takt.Interval = [TimeSpan]::FromMilliseconds(200)
$script:Takt.Add_Tick({
    if ($script:Scannt) { $ui.PlatzStatus.Text = 'Scanne ... {0:N0} Ordner' -f [PulsScan]::Ordner }
    foreach ($j in @($script:Jobs)) {
        if (-not $j.H.IsCompleted) { continue }
        [void]$script:Jobs.Remove($j)
        $res = $null
        try { $res = $j.Ps.EndInvoke($j.H) } catch { Log "Hintergrundaufgabe fehlgeschlagen: $($_.Exception.Message)" 'fehler' }
        $j.Ps.Dispose()
        try { & $j.Fertig $res } catch { Log "Fehler: $($_.Exception.Message)" 'fehler' }
    }
})

$script:Geladen = $false
$fenster.Add_ContentRendered({
    if ($script:Geladen) { return }
    $script:Geladen = $true
    $ui.AdminInfo.Text = 'Backups: ' + $script:Ablage
    Log 'PULS gestartet.'
    if (-not $script:IstAdmin) { Log 'Ohne Adminrechte gestartet - Tweaks, Bloatware und DNS sind gesperrt.' 'warn' }
    foreach ($f in 'Uebersicht-Laden', 'Tweaks-Bauen', 'Bloat-Laden', 'Dns-Anzeigen') {
        try { & $f } catch { Log "$f : $($_.Exception.Message)" 'fehler' }
    }
    if (-not $script:IstAdmin) { Set-Busy $true }
    $script:Takt.Start()
    if ($env:PULS_SCREENSHOT) { Testmodus }
})
$fenster.Add_Closed({ $script:Takt.Stop() })

# ---------- Testmodus: Screenshots aller Seiten (nur fuer Entwicklung) ----------
function Testmodus {
    Hogs-Start; Dns-Test; Analyse-Start; Platz-Scan "$env:USERPROFILE\Documents"
    $script:Shot = New-Object Windows.Threading.DispatcherTimer
    $script:Shot.Interval = [TimeSpan]::FromSeconds(25)
    $script:Shot.Add_Tick({
        $script:Shot.Stop()
        foreach ($s in $script:Seiten) {
            $ui["Nav$s"].IsChecked = $true
            $fenster.UpdateLayout()
            $root = $fenster.Content
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($root)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create((Join-Path $env:PULS_SCREENSHOT "$s.png")); $enc.Save($fs); $fs.Close()
        }
        $fenster.Close()
    })
    $script:Shot.Start()
}

[void]$fenster.ShowDialog()
