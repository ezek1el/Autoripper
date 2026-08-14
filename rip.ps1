# =====================================================================
#  AutoRip.ps1 (v4.1) - Automatisches Rippen von Video-DVDs / Video-CDs zu MKV
#  Author: ezek1el3000
#
#  v4.1: Farben der Fortschrittsanzeige konfigurierbar - kein grelles
#        Cyan mehr (siehe $ProgressFg / $ProgressBg in der Konfiguration).
#
#  v4-Aenderungen:
#  - Live-Fortschrittsbalken (Write-Progress) fuer MakeMKV, ffmpeg-Remux
#    und Datei-Kopien: Prozent, verstrichene Zeit, geschaetzte Restzeit.
#  - Heartbeat: Spinner tickt alle 0,5s unabhaengig davon, ob der
#    Ripper gerade Ausgabe liefert. Liefert MakeMKV laenger nichts,
#    zeigt die Statuszeile "keine Ausgabe seit Xs" an (ab 2 min
#    zusaetzlich eine gelbe Warnung im Log) - so ist unterscheidbar,
#    ob das Script haengt (tut es nicht) oder das Laufwerk kaempft.
#  - MakeMKV laeuft jetzt als eigener Prozess, dessen Robot-Output
#    live aus der _makemkv.log getailt und geparst wird (PRGV/PRGT).
#
#  Ablauf:  Disc einlegen -> Erkennung (DVD / BD / VCD / SVCD / Daten)
#           -> Ordner unter $OutputRoot anlegen -> MKV rippen -> Auswurf
#
#  Start:   powershell -NoProfile -ExecutionPolicy Bypass -File AutoRip.ps1
#  Beenden: Strg+C
# =====================================================================

# ------------------------- Konfiguration -----------------------------
$OutputRoot    = 'E:\Rips'      # Zielordner
$FFmpeg        = 'ffmpeg'       # fuer VCDs und Daten-Disc-Remux
$MinLengthSec  = 120            # DVD-Titel unter dieser Laenge ignorieren
$EjectWhenDone = $true          # Disc nach dem Rippen auswerfen
$PollSeconds   = 5              # Pruefintervall fuer neue Discs

# Farben der Fortschrittsanzeige (gueltige Werte: ConsoleColor-Namen,
# z.B. Black, DarkGray, Gray, DarkGreen, Green, Yellow, White ...)
$ProgressFg    = 'Green'        # Text- und Balkenfarbe
$ProgressBg    = 'Black'        # Hintergrund (Standard waere grelles Cyan)

# Dateiendungen, die auf Daten-Discs als Video eingesammelt werden
$VideoExts     = '\.(avi|mpg|mpeg|mp4|m4v|wmv|mov|flv|vob|ts|m2ts|mkv|divx|asf|3gp)$'

# makemkvcon.exe automatisch finden (Pfad bei Bedarf fest eintragen)
$MakeMKVCon = @(
    'C:\Program Files (x86)\MakeMKV\makemkvcon.exe',
    'C:\Program Files\MakeMKV\makemkvcon64.exe',
    'C:\Program Files\MakeMKV\makemkvcon.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
# ---------------------------------------------------------------------

$Spinner = @('|','/','-','\')

function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg) -ForegroundColor $Color
}

function Format-Time([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1) { return $ts.ToString('h\:mm\:ss') }
    return $ts.ToString('mm\:ss')
}

# --- Einheitliche Fortschrittszeile -----------------------------------
# Pct: 0-100 | Start: Startzeitpunkt | Tick: Spinnerzaehler
# SilenceSec: Sekunden ohne Lebenszeichen (0 = nicht anzeigen)
function Show-RipProgress {
    param(
        [string]$Activity,
        [double]$Pct,
        [datetime]$Start,
        [int]$Tick,
        [string]$Sub = '',
        [double]$SilenceSec = 0
    )
    $elapsed = (Get-Date) - $Start
    if ($Pct -gt 1 -and $Pct -lt 100) {
        $remainSec = $elapsed.TotalSeconds / $Pct * (100 - $Pct)
        $eta = 'Rest ~' + (Format-Time ([TimeSpan]::FromSeconds([int]$remainSec)))
    } else {
        $eta = 'Rest wird berechnet'
    }
    $status = ('{0} {1}%  |  {2} vergangen  |  {3}' -f `
        $Spinner[$Tick % 4], [math]::Round($Pct, 1), (Format-Time $elapsed), $eta)
    if ($SilenceSec -ge 15) {
        $status += ('  |  keine Ausgabe seit {0}s' -f [int]$SilenceSec)
    }
    $wp = @{
        Id              = 1
        Activity        = $Activity
        Status          = $status
        PercentComplete = [int][math]::Max(0, [math]::Min(100, $Pct))
    }
    if ($Sub) { $wp.CurrentOperation = $Sub }
    Write-Progress @wp
}

# --- Disc-Zugriffe ueber .NET: immun gegen kaputte Zeitstempel --------
function Test-DiscDir([string]$Path) {
    return [System.IO.Directory]::Exists($Path)
}

function Test-DriveReady([string]$Drive) {
    try { return (New-Object System.IO.DriveInfo($Drive.Substring(0,1))).IsReady }
    catch { return $false }
}

function Find-VideoFiles([string]$Drive) {
    try {
        return @([System.IO.Directory]::GetFiles("$Drive\", '*', [System.IO.SearchOption]::AllDirectories) |
                 Where-Object { $_ -match $VideoExts } | Sort-Object)
    } catch {
        Write-Log "Disc nicht vollstaendig lesbar: $($_.Exception.Message)" 'Yellow'
        return @()
    }
}

# --- Disc-Auswurf ueber winmm (sprachunabhaengig) ---------------------
Add-Type -Namespace Win32 -Name CDTray -MemberDefinition @'
[DllImport("winmm.dll", CharSet = CharSet.Auto)]
public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int retLen, IntPtr cb);
'@

function Eject-Disc([string]$Drive) {
    [void][Win32.CDTray]::mciSendString("open $Drive type cdaudio alias ripdrv shareable", $null, 0, [IntPtr]::Zero)
    [void][Win32.CDTray]::mciSendString("set ripdrv door open", $null, 0, [IntPtr]::Zero)
    [void][Win32.CDTray]::mciSendString("close ripdrv", $null, 0, [IntPtr]::Zero)
}

# --- MakeMKV-Laufwerksindex zum Windows-Laufwerksbuchstaben ermitteln
function Get-MakeMKVDiscIndex([string]$Drive) {
    $out = & $MakeMKVCon -r --cache=1 info disc:9999 2>$null
    foreach ($line in $out) {
        if ($line -match '^DRV:(\d+),.*"([A-Za-z]:)"\s*$' -and $Matches[2] -ieq $Drive) {
            return [int]$Matches[1]
        }
    }
    return $null
}

# --- Zielordner aus Disc-Label bauen ----------------------------------
function New-RipFolder([string]$Label) {
    $safe = ($Label -replace '[\\/:*?"<>|]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'DISC' }
    $path = Join-Path $OutputRoot $safe
    if (Test-Path $path) {
        $path = Join-Path $OutputRoot ("{0}_{1}" -f $safe, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

# --- DVD / Blu-ray mit MakeMKV rippen (mit Live-Fortschritt) ----------
function Rip-WithMakeMKV([string]$Drive, [string]$Folder) {
    if (-not $MakeMKVCon) {
        Write-Log 'makemkvcon.exe nicht gefunden - MakeMKV installieren oder Pfad oben eintragen.' 'Red'
        return $false
    }
    $idx = Get-MakeMKVDiscIndex $Drive
    if ($null -eq $idx) {
        Write-Log 'Laufwerk in MakeMKV nicht gefunden, versuche disc:0 ...' 'Yellow'
        $idx = 0
    }

    $log    = Join-Path $Folder '_makemkv.log'
    $errLog = Join-Path $Folder '_makemkv.err.log'
    Write-Log "Starte MakeMKV (disc:$idx) - Rohprotokoll: _makemkv.log" 'Cyan'

    $mkArgs = ('--minlength={0} -r --progress=-same mkv disc:{1} all "{2}"' -f $MinLengthSec, $idx, $Folder)
    $proc = Start-Process -FilePath $MakeMKVCon -ArgumentList $mkArgs `
            -RedirectStandardOutput $log -RedirectStandardError $errLog `
            -NoNewWindow -PassThru

    # Warten bis die Logdatei existiert, dann live mittailen
    while (-not [System.IO.File]::Exists($log) -and -not $proc.HasExited) { Start-Sleep -Milliseconds 100 }

    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::OpenOrCreate,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)

        $start = Get-Date; $lastOut = Get-Date
        $pct = 0.0; $task = 'Disc wird analysiert'; $sub = ''
        $tick = 0; $stallWarned = $false

        while ($true) {
            # alle neu geschriebenen Zeilen einsammeln und parsen
            while ($null -ne ($line = $sr.ReadLine())) {
                $lastOut = Get-Date
                if ($line -match '^PRGV:(\d+),(\d+),(\d+)') {
                    $max = [double]$Matches[3]
                    if ($max -gt 0) { $pct = [double]$Matches[2] / $max * 100 }
                }
                elseif ($line -match '^PRGT:\d+,\d+,"(.*)"') { $task = $Matches[1] }
                elseif ($line -match '^PRGC:\d+,\d+,"(.*)"') { $sub  = $Matches[1] }
            }

            $silence = ((Get-Date) - $lastOut).TotalSeconds
            Show-RipProgress -Activity "MakeMKV: $task" -Pct $pct -Start $start `
                             -Tick $tick -Sub $sub -SilenceSec $silence
            $tick++

            if ($silence -ge 120 -and -not $stallWarned) {
                Write-Log ('MakeMKV liefert seit {0}s keine Ausgabe - Laufwerk kaempft evtl. mit Lesefehlern. Script laeuft weiter.' -f [int]$silence) 'Yellow'
                $stallWarned = $true
            }
            if ($silence -lt 120) { $stallWarned = $false }

            if ($proc.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
        Write-Progress -Id 1 -Activity 'MakeMKV' -Completed
    }

    $mkvs = @(Get-ChildItem $Folder -Filter *.mkv -ErrorAction SilentlyContinue)
    return ($mkvs.Count -gt 0)
}

# --- Datei mit Fortschrittsanzeige kopieren ---------------------------
function Copy-FileWithProgress([string]$Src, [string]$Dst, [string]$Activity) {
    $total = ([System.IO.FileInfo]::new($Src)).Length
    if ($total -le 0) { $total = 1 }
    $in = $null; $out = $null
    try {
        $in  = [System.IO.File]::Open($Src, [System.IO.FileMode]::Open,
               [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $out = [System.IO.File]::Create($Dst)
        $buf = New-Object byte[] (4MB)
        $done = [long]0; $start = Get-Date; $tick = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            Show-RipProgress -Activity $Activity -Pct ($done / $total * 100) -Start $start -Tick $tick
            $tick++
        }
        return $true
    } catch {
        Write-Log "Kopieren fehlgeschlagen: $($_.Exception.Message)" 'Red'
        return $false
    } finally {
        if ($in)  { $in.Dispose() }
        if ($out) { $out.Dispose() }
        Write-Progress -Id 1 -Activity 'Kopieren' -Completed
    }
}

# --- Dateiliste nach MKV remuxen (ffmpeg -c copy), Fallback: Kopie ----
function Rip-Files([string[]]$Files, [string]$Folder) {
    $haveFF = [bool](Get-Command $FFmpeg -ErrorAction SilentlyContinue)
    if (-not $haveFF) {
        Write-Log 'ffmpeg nicht gefunden - Dateien werden nur 1:1 kopiert (winget install Gyan.FFmpeg fuer MKV-Remux).' 'Yellow'
    }
    $log   = Join-Path $Folder '_ffmpeg.log'
    $okAny = $false
    $count = $Files.Count

    for ($i = 0; $i -lt $count; $i++) {
        $f    = $Files[$i]
        $name = [System.IO.Path]::GetFileName($f)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $dest = Join-Path $Folder ($base + '.mkv')
        $n = 2
        while ([System.IO.File]::Exists($dest)) {
            $dest = Join-Path $Folder ('{0}_{1}.mkv' -f $base, $n); $n++
        }
        $label = ('Datei {0}/{1}: {2}' -f ($i + 1), $count, $name)

        $done = $false
        if ($haveFF -and $f -notmatch '\.mkv$') {
            Write-Log "Remuxe $name -> $([System.IO.Path]::GetFileName($dest))" 'Cyan'
            $srcSize = ([System.IO.FileInfo]::new($f)).Length
            if ($srcSize -le 0) { $srcSize = 1 }
            $tmpErr  = Join-Path $Folder '_ffmpeg.tmp'
            $ffArgs  = ('-hide_banner -loglevel error -fflags +genpts -i "{0}" -c copy -y "{1}"' -f $f, $dest)
            $p = Start-Process -FilePath $FFmpeg -ArgumentList $ffArgs `
                 -RedirectStandardError $tmpErr -NoNewWindow -PassThru

            # Fortschritt = Zielgroesse vs. Quellgroesse (bei -c copy ~1:1)
            $start = Get-Date; $tick = 0
            $lastSize = [long]0; $lastGrow = Get-Date
            while (-not $p.HasExited) {
                $cur = [long]0
                if ([System.IO.File]::Exists($dest)) { $cur = ([System.IO.FileInfo]::new($dest)).Length }
                if ($cur -gt $lastSize) { $lastSize = $cur; $lastGrow = Get-Date }
                $silence = ((Get-Date) - $lastGrow).TotalSeconds
                Show-RipProgress -Activity "Remux: $label" -Pct ($cur / $srcSize * 100) `
                                 -Start $start -Tick $tick -SilenceSec $silence
                $tick++
                Start-Sleep -Milliseconds 400
            }
            Write-Progress -Id 1 -Activity 'Remux' -Completed

            # ffmpeg-Fehlerausgabe ins Sammellog uebernehmen
            if ([System.IO.File]::Exists($tmpErr)) {
                $errTxt = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
                if ($errTxt) { Add-Content $log ("--- {0} ---`r`n{1}" -f $name, $errTxt) }
                Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
            }

            if ($p.ExitCode -eq 0 -and [System.IO.File]::Exists($dest) -and
                ([System.IO.FileInfo]::new($dest)).Length -gt 0) {
                $done = $true
            } else {
                Write-Log 'Remux fehlgeschlagen (_ffmpeg.log), kopiere Original.' 'Yellow'
                if ([System.IO.File]::Exists($dest)) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $done) {
            $destOrig = Join-Path $Folder $name
            Write-Log "Kopiere $name" 'Cyan'
            $done = Copy-FileWithProgress $f $destOrig ('Kopiere: ' + $label)
        }
        if ($done) { $okAny = $true }
    }
    return $okAny
}

# --- Video-CD / Super-Video-CD ----------------------------------------
function Rip-VCD([string]$Drive, [string]$Folder, [bool]$SVCD) {
    $src = if ($SVCD) { "$Drive\MPEG2" } else { "$Drive\MPEGAV" }
    $files = @()
    try {
        $files = @([System.IO.Directory]::GetFiles($src) |
                   Where-Object { $_ -match '\.(dat|mpg)$' } | Sort-Object)
    } catch {}
    if (-not $files) { Write-Log "Keine Videodateien in $src gefunden." 'Red'; return $false }
    return (Rip-Files $files $Folder)
}

# --- Hauptverarbeitung pro eingelegter Disc ---------------------------
function Process-Disc([string]$Drive) {
    Start-Sleep -Seconds 2

    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
    if (-not $disk -or $disk.DriveType -ne 5) { return }
    if (-not (Test-DriveReady $Drive)) { return }

    $label = $disk.VolumeName
    Write-Log "Disc erkannt in $Drive - Label: '$label'" 'Green'

    $isDVD  = Test-DiscDir "$Drive\VIDEO_TS"
    $isBD   = Test-DiscDir "$Drive\BDMV"
    $isVCD  = Test-DiscDir "$Drive\MPEGAV"     # Video-CD
    $isSVCD = Test-DiscDir "$Drive\MPEG2"      # Super-Video-CD

    $ok = $false
    $folder = $null

    if ($isDVD -or $isBD) {
        $folder = New-RipFolder $label
        Write-Log "Zielordner: $folder"
        $ok = Rip-WithMakeMKV $Drive $folder
    }
    elseif ($isVCD -or $isSVCD) {
        $folder = New-RipFolder $label
        Write-Log "Zielordner: $folder"
        $ok = Rip-VCD $Drive $folder $isSVCD
    }
    else {
        # Fallback: Daten-Disc mit losen Videodateien?
        $videos = Find-VideoFiles $Drive
        if ($videos.Count -gt 0) {
            Write-Log "Daten-Disc mit $($videos.Count) Videodatei(en) - Fallback-Modus." 'Cyan'
            $folder = New-RipFolder $label
            Write-Log "Zielordner: $folder"
            $ok = Rip-Files $videos $folder
        }
        else {
            Write-Log 'Keine Video-Disc und keine Videodateien gefunden - wird ignoriert.' 'Yellow'
            try {
                $names = [System.IO.Directory]::GetFileSystemEntries("$Drive\") |
                         ForEach-Object { [System.IO.Path]::GetFileName($_) }
                Write-Log ("Root-Inhalt: " + ($names -join ', ')) 'Yellow'
            } catch {
                Write-Log "Root nicht lesbar: $($_.Exception.Message)" 'Yellow'
            }
            return
        }
    }

    if ($ok) {
        Write-Log "Fertig: $folder" 'Green'
        if ($EjectWhenDone) { Eject-Disc $Drive; Write-Log 'Disc ausgeworfen - naechste bitte.' 'Green' }
    } else {
        Write-Log 'FEHLER beim Rippen - Details siehe Logdatei im Zielordner.' 'Red'
    }
}

# ============================== Start =================================
if (-not (Test-Path $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }

# Write-Progress-Farben umstellen (Konsolen-Standard: Gelb auf DarkCyan,
# was Windows Terminal je nach Farbschema als grelles Tuerkis rendert)
try {
    $Host.PrivateData.ProgressForegroundColor = $ProgressFg
    $Host.PrivateData.ProgressBackgroundColor = $ProgressBg
} catch { }

Write-Log "AutoRip v4.1 gestartet - pruefe alle $PollSeconds s auf Discs (Beenden mit Strg+C)" 'Green'
if ($MakeMKVCon) { Write-Log "MakeMKV: $MakeMKVCon" } else { Write-Log 'WARNUNG: MakeMKV nicht gefunden!' 'Red' }

# Merkt sich pro Laufwerk die zuletzt verarbeitete Disc (Label + Seriennummer).
# Wird geleert, sobald das Laufwerk leer ist -> dieselbe Disc kann nach
# Auswurf + erneutem Einlegen bewusst nochmal gerippt werden.
$LastSig = @{}

while ($true) {
    $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
        $drive = $d.DeviceID

        # Laufwerk leer? -> Merker zuruecksetzen
        if (-not (Test-DriveReady $drive)) {
            if ($LastSig.ContainsKey($drive)) {
                $LastSig.Remove($drive)
                Write-Log "$drive leer - bereit fuer die naechste Disc."
            }
            continue
        }

        # Disc noch am Mounten (keine Seriennummer)? -> naechster Durchlauf
        if (-not $d.VolumeSerialNumber) { continue }

        $sig = '{0}|{1}' -f $d.VolumeName, $d.VolumeSerialNumber
        if ($LastSig[$drive] -eq $sig) { continue }   # diese Disc wurde schon verarbeitet

        $LastSig[$drive] = $sig
        Process-Disc $drive
    }
    Start-Sleep -Seconds $PollSeconds
}