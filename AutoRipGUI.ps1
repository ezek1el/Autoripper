# =====================================================================
#  AutoRipGUI.ps1 (v5.2) - ezek1el3000's AutoRip (WPF-Oberflaeche)
#  Author: ezek1el3000
#
#  v5.3: Eigene Button-/ListBox-Templates - Hover, Gedrueckt, Disabled
#        und Auswahl jetzt dezent dunkel statt hellem Windows-Chrome.
#  v5.2: Script koppelt sich beim Start vom Konsolenfenster ab (laeuft
#        als eigener versteckter Prozess weiter). Das aufrufende
#        PowerShell-Fenster kann sofort geschlossen werden, die GUI
#        bleibt offen. Schliessen der GUI beendet alles sauber.
#        Debug-Modus: Start mit -ShowConsole (keine Abkopplung).
#  v5.1: Branding "ezek1el3000's AutoRip" + Watcher startet automatisch
#        beim Programmstart und wartet auf Discs (wie die CLI-Version).
#        Stopp pausiert die Ueberwachung, Start setzt sie fort.
#
#  Architektur:
#  - UI-Thread: WPF-Fenster (XAML), DispatcherTimer aktualisiert alle
#    250ms Statuszeile, Fortschrittsbalken und Protokoll.
#  - Worker: kompletter Watcher/Ripper (Logik aus AutoRip.ps1 v4.1)
#    laeuft in einem eigenen Runspace und kommuniziert ausschliesslich
#    ueber eine synchronisierte Hashtable ($Sync) - keine direkten
#    UI-Zugriffe aus dem Worker.
#  - Einstellungen werden in %APPDATA%\AutoRip\settings.json gespeichert.
#
#  Start:   powershell -NoProfile -ExecutionPolicy Bypass -File AutoRipGUI.ps1
#  Debug:   ... -File AutoRipGUI.ps1 -ShowConsole
#           (Konsole bleibt sichtbar und mit der GUI verbunden)
#  (powershell.exe laeuft ab PS 3.0 standardmaessig im STA-Modus,
#   was WPF voraussetzt.)
# =====================================================================

param(
    [switch]$Detached,      # intern: gesetzt vom abgekoppelten Klon
    [switch]$ShowConsole    # Debug: Konsole sichtbar lassen, keine Abkopplung
)

# --- Vom Konsolenfenster abkoppeln ------------------------------------
# Beim ersten Start klont sich das Script als versteckten, eigenstaendigen
# Prozess und beendet sich sofort. Das aufrufende PowerShell-Fenster ist
# damit frei und kann geschlossen werden - die GUI lebt im abgekoppelten
# Prozess weiter und beendet beim Schliessen alles selbst.
if (-not $Detached -and -not $ShowConsole) {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $PSCommandPath), '-Detached'
    )
    exit
}

# Eigene (versteckte) Konsole zusaetzlich per WinAPI verbergen - falls
# Windows Terminal als Standard-Host das -WindowStyle Hidden ignoriert.
if (-not $ShowConsole) {
    try {
        if (-not ('Native.ConsoleUtil' -as [type])) {
            Add-Type -Namespace Native -Name ConsoleUtil -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
        }
        $hCon = [Native.ConsoleUtil]::GetConsoleWindow()
        if ($hCon -ne [IntPtr]::Zero) { [void][Native.ConsoleUtil]::ShowWindow($hCon, 0) }   # 0 = SW_HIDE
    } catch {}
}

# --- Voraussetzungen ---------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host 'WPF benoetigt STA - bitte ohne -MTA starten.' -ForegroundColor Red
    exit 1
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # fuer den Ordner-Dialog

# ======================================================================
#  XAML - Fensterdefinition (dunkles Theme, Indigo-Akzent)
# ======================================================================
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ezek1el3000's AutoRip" Height="640" Width="860" MinHeight="500" MinWidth="720"
        WindowStartupLocation="CenterScreen" Background="#1b1b1f"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <!-- Eigenes Button-Template: das WPF-Standard-Chrome ignoriert bei
         Hover/Disabled die gesetzten Farben und wird auf dunklem Theme
         unlesbar. Hover = dezente Aufhellung per Overlay (funktioniert
         auf grauen wie auf Indigo-Buttons), Gedrueckt = leicht dunkler,
         Disabled = gedimmt. -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="#35353b"/>
      <Setter Property="Foreground" Value="#e8e8ec"/>
      <Setter Property="BorderBrush" Value="#3a3a42"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <Grid>
                <Border x:Name="Overlay" Background="#ffffff" Opacity="0" CornerRadius="4"/>
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                  Margin="{TemplateBinding Padding}"
                                  RecognizesAccessKey="True"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Overlay" Property="Opacity" Value="0.10"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Overlay" Property="Background" Value="#000000"/>
                <Setter TargetName="Overlay" Property="Opacity" Value="0.25"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Kopfzeile -->
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="ezek1el3000's" FontSize="22" FontWeight="Bold" Foreground="#8b8cf8"/>
      <TextBlock Text=" AutoRip" FontSize="22" FontWeight="Bold" Foreground="#e8e8ec"/>
      <TextBlock Text=" v5.3" FontSize="12" Foreground="#6a6a74" VerticalAlignment="Bottom" Margin="4,0,0,3"/>
      <TextBlock x:Name="StateText" Text="Bereit" FontSize="14" Foreground="#8b8cf8"
                 DockPanel.Dock="Right" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </DockPanel>

    <!-- Einstellungen -->
    <Border Grid.Row="1" Background="#242429" CornerRadius="8" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Text="Zielordner" Foreground="#c9c9cf"
                   VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBox  x:Name="OutPath" Grid.Row="0" Grid.Column="1" Height="26"
                  Background="#141417" Foreground="#e8e8ec" BorderBrush="#3a3a42"
                  CaretBrush="#e8e8ec" VerticalContentAlignment="Center" Padding="6,0"/>
        <Button   x:Name="BtnBrowse" Grid.Row="0" Grid.Column="2" Content="Durchsuchen..."
                  Margin="8,0,0,0" Padding="10,3" Background="#35353b" Foreground="#e8e8ec"
                  BorderBrush="#3a3a42"/>

        <StackPanel Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,10,0,0">
          <TextBlock Text="Min. Titell&#228;nge (Sek.)" Foreground="#c9c9cf" VerticalAlignment="Center"/>
          <TextBox x:Name="MinLen" Width="60" Height="26" Margin="8,0,20,0"
                   Background="#141417" Foreground="#e8e8ec" BorderBrush="#3a3a42"
                   CaretBrush="#e8e8ec" VerticalContentAlignment="Center" TextAlignment="Center"/>
          <CheckBox x:Name="EjectBox" Content="Disc nach dem Rippen auswerfen"
                    Foreground="#c9c9cf" VerticalAlignment="Center" IsChecked="True"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Grid.Column="2" Orientation="Horizontal" Margin="8,10,0,0"
                    HorizontalAlignment="Right">
          <Button x:Name="BtnOpen"  Content="Ordner &#246;ffnen" Padding="10,3" Margin="0,0,8,0"
                  Background="#35353b" Foreground="#e8e8ec" BorderBrush="#3a3a42"/>
          <Button x:Name="BtnStart" Content="&#9654;  Start" Padding="14,3" Margin="0,0,8,0"
                  Background="#6366f1" Foreground="White" BorderBrush="#6366f1" FontWeight="SemiBold"/>
          <Button x:Name="BtnStop"  Content="&#9632;  Stopp" Padding="14,3" IsEnabled="False"
                  Background="#35353b" Foreground="#e8e8ec" BorderBrush="#3a3a42"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Aktuelle Disc / Taetigkeit -->
    <StackPanel Grid.Row="2" Margin="2,0,0,6">
      <TextBlock x:Name="DiscText" Text="" Foreground="#e8e8ec" FontSize="14" FontWeight="SemiBold"/>
      <TextBlock x:Name="ActivityText" Text="" Foreground="#c9c9cf"/>
      <TextBlock x:Name="SubText" Text="" Foreground="#6a6a74" FontSize="12"/>
    </StackPanel>

    <!-- Fortschritt -->
    <StackPanel Grid.Row="3" Margin="0,0,0,10">
      <ProgressBar x:Name="Bar" Height="20" Minimum="0" Maximum="100"
                   Foreground="#6366f1" Background="#141417" BorderBrush="#3a3a42"/>
      <TextBlock x:Name="ProgText" Text="Bereit." Foreground="#9a9aa3" FontFamily="Consolas"
                 FontSize="12" Margin="2,4,0,0"/>
    </StackPanel>

    <!-- Protokoll -->
    <Border Grid.Row="4" Background="#141417" CornerRadius="8" Padding="6">
      <DockPanel>
        <TextBlock DockPanel.Dock="Top" Text="Protokoll" Foreground="#6a6a74" FontSize="11"
                   Margin="4,0,0,4"/>
        <ListBox x:Name="LogList" Background="Transparent" BorderThickness="0"
                 Foreground="#c9c9cf" FontFamily="Consolas" FontSize="12"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
          <ListBox.ItemContainerStyle>
            <Style TargetType="ListBoxItem">
              <Setter Property="Padding" Value="4,1"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ListBoxItem">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="3"
                            Padding="{TemplateBinding Padding}">
                      <ContentPresenter/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="#14ffffff"/>
                      </Trigger>
                      <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="#2e2e36"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
          </ListBox.ItemContainerStyle>
        </ListBox>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

# ======================================================================
#  Worker-Script (laeuft im Background-Runspace)
#  Kommuniziert nur ueber $S (synchronisierte Hashtable):
#    Lesen : S.Cfg (Konfiguration), S.Stop (Abbruchflag)
#    Setzen: S.State, S.DiscLabel, S.Activity, S.Sub, S.Pct,
#            S.Ripping, S.RipStart, S.LastActivity, S.ChildPid,
#            S.Log (Queue mit @{T;M;C})
# ======================================================================
$WorkerScript = @'
$ErrorActionPreference = 'Continue'

$Cfg           = $S.Cfg
$OutputRoot    = $Cfg.OutputRoot
$MinLengthSec  = $Cfg.MinLength
$EjectWhenDone = $Cfg.Eject
$PollSeconds   = 5
$FFmpeg        = 'ffmpeg'
$VideoExts     = '\.(avi|mpg|mpeg|mp4|m4v|wmv|mov|flv|vob|ts|m2ts|mkv|divx|asf|3gp)$'

$MakeMKVCon = @(
    'C:\Program Files (x86)\MakeMKV\makemkvcon.exe',
    'C:\Program Files\MakeMKV\makemkvcon64.exe',
    'C:\Program Files\MakeMKV\makemkvcon.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Log([string]$m, [string]$c = 'Gray') {
    $S.Log.Enqueue(@{ T = (Get-Date); M = $m; C = $c })
}
function Touch { $S.LastActivity = Get-Date }
function Set-Prog([string]$a, [double]$p, [string]$sub = '') {
    $S.Activity = $a; $S.Pct = $p; $S.Sub = $sub
}
function Sleep-Stop([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end -and -not $S.Stop) { Start-Sleep -Milliseconds 150 }
}

# --- Disc-Zugriffe ueber .NET (immun gegen kaputte Zeitstempel) -------
function Test-DiscDir([string]$Path) { return [System.IO.Directory]::Exists($Path) }
function Test-DriveReady([string]$Drive) {
    try { return (New-Object System.IO.DriveInfo($Drive.Substring(0,1))).IsReady }
    catch { return $false }
}
function Find-VideoFiles([string]$Drive) {
    try {
        return @([System.IO.Directory]::GetFiles("$Drive\", '*', [System.IO.SearchOption]::AllDirectories) |
                 Where-Object { $_ -match $VideoExts } | Sort-Object)
    } catch {
        Log "Disc nicht vollstaendig lesbar: $($_.Exception.Message)" 'Yellow'
        return @()
    }
}

# --- Auswurf ueber winmm ----------------------------------------------
if (-not ('Win32.CDTray' -as [type])) {
    Add-Type -Namespace Win32 -Name CDTray -MemberDefinition '[DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int retLen, IntPtr cb);'
}
function Eject-Disc([string]$Drive) {
    [void][Win32.CDTray]::mciSendString("open $Drive type cdaudio alias ripdrv shareable", $null, 0, [IntPtr]::Zero)
    [void][Win32.CDTray]::mciSendString("set ripdrv door open", $null, 0, [IntPtr]::Zero)
    [void][Win32.CDTray]::mciSendString("close ripdrv", $null, 0, [IntPtr]::Zero)
}

function Get-MakeMKVDiscIndex([string]$Drive) {
    $out = & $MakeMKVCon -r --cache=1 info disc:9999 2>$null
    foreach ($line in $out) {
        if ($line -match '^DRV:(\d+),.*"([A-Za-z]:)"\s*$' -and $Matches[2] -ieq $Drive) {
            return [int]$Matches[1]
        }
    }
    return $null
}

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

# --- DVD / Blu-ray mit MakeMKV ----------------------------------------
function Rip-WithMakeMKV([string]$Drive, [string]$Folder) {
    if (-not $MakeMKVCon) {
        Log 'makemkvcon.exe nicht gefunden - MakeMKV installieren.' 'Red'
        return $false
    }
    $idx = Get-MakeMKVDiscIndex $Drive
    if ($null -eq $idx) {
        Log 'Laufwerk in MakeMKV nicht gefunden, versuche disc:0 ...' 'Yellow'
        $idx = 0
    }
    $log    = Join-Path $Folder '_makemkv.log'
    $errLog = Join-Path $Folder '_makemkv.err.log'
    Log "Starte MakeMKV (disc:$idx) - Rohprotokoll: _makemkv.log" 'Cyan'

    $mkArgs = ('--minlength={0} -r --progress=-same mkv disc:{1} all "{2}"' -f $MinLengthSec, $idx, $Folder)
    $proc = Start-Process -FilePath $MakeMKVCon -ArgumentList $mkArgs `
            -RedirectStandardOutput $log -RedirectStandardError $errLog `
            -WindowStyle Hidden -PassThru
    $S.ChildPid = $proc.Id

    while (-not [System.IO.File]::Exists($log) -and -not $proc.HasExited) { Start-Sleep -Milliseconds 100 }

    $fs = $null; $sr = $null
    $aborted = $false
    try {
        $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::OpenOrCreate,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)

        $task = 'Disc wird analysiert'; $sub = ''
        Set-Prog "MakeMKV: $task" -1
        Touch
        $stallWarned = $false

        while ($true) {
            while ($null -ne ($line = $sr.ReadLine())) {
                Touch
                if ($line -match '^PRGV:(\d+),(\d+),(\d+)') {
                    $max = [double]$Matches[3]
                    if ($max -gt 0) { $S.Pct = [double]$Matches[2] / $max * 100 }
                }
                elseif ($line -match '^PRGT:\d+,\d+,"(.*)"') { $task = $Matches[1]; $S.Activity = "MakeMKV: $task" }
                elseif ($line -match '^PRGC:\d+,\d+,"(.*)"') { $S.Sub = $Matches[1] }
            }

            $silence = ((Get-Date) - $S.LastActivity).TotalSeconds
            if ($silence -ge 120 -and -not $stallWarned) {
                Log ('MakeMKV liefert seit {0}s keine Ausgabe - Laufwerk kaempft evtl. mit Lesefehlern.' -f [int]$silence) 'Yellow'
                $stallWarned = $true
            }
            if ($silence -lt 120) { $stallWarned = $false }

            if ($S.Stop) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                $aborted = $true
                break
            }
            if ($proc.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
        $S.ChildPid = 0
    }
    if ($aborted) { return $false }

    $mkvs = @(Get-ChildItem $Folder -Filter *.mkv -ErrorAction SilentlyContinue)
    return ($mkvs.Count -gt 0)
}

# --- Datei mit Fortschritt kopieren -----------------------------------
function Copy-FileWithProgress([string]$Src, [string]$Dst, [string]$Label) {
    $total = ([System.IO.FileInfo]::new($Src)).Length
    if ($total -le 0) { $total = 1 }
    $in = $null; $out = $null
    try {
        $in  = [System.IO.File]::Open($Src, [System.IO.FileMode]::Open,
               [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $out = [System.IO.File]::Create($Dst)
        $buf = New-Object byte[] (4MB)
        $done = [long]0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($S.Stop) {
                $out.Dispose(); $out = $null
                Remove-Item $Dst -Force -ErrorAction SilentlyContinue
                return $false
            }
            $out.Write($buf, 0, $n)
            $done += $n
            Set-Prog "Kopiere: $Label" ($done / $total * 100)
            Touch
        }
        return $true
    } catch {
        Log "Kopieren fehlgeschlagen: $($_.Exception.Message)" 'Red'
        return $false
    } finally {
        if ($in)  { $in.Dispose() }
        if ($out) { $out.Dispose() }
    }
}

# --- Dateiliste nach MKV remuxen, Fallback: Kopie ---------------------
function Rip-Files([string[]]$Files, [string]$Folder) {
    $haveFF = [bool](Get-Command $FFmpeg -ErrorAction SilentlyContinue)
    if (-not $haveFF) {
        Log 'ffmpeg nicht gefunden - Dateien werden nur 1:1 kopiert (winget install Gyan.FFmpeg).' 'Yellow'
    }
    $log   = Join-Path $Folder '_ffmpeg.log'
    $okAny = $false
    $count = $Files.Count

    for ($i = 0; $i -lt $count; $i++) {
        if ($S.Stop) { return $okAny }
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
            Log "Remuxe $name -> $([System.IO.Path]::GetFileName($dest))" 'Cyan'
            $srcSize = ([System.IO.FileInfo]::new($f)).Length
            if ($srcSize -le 0) { $srcSize = 1 }
            $tmpErr  = Join-Path $Folder '_ffmpeg.tmp'
            $ffArgs  = ('-hide_banner -loglevel error -fflags +genpts -i "{0}" -c copy -y "{1}"' -f $f, $dest)
            $p = Start-Process -FilePath $FFmpeg -ArgumentList $ffArgs `
                 -RedirectStandardError $tmpErr -WindowStyle Hidden -PassThru
            $S.ChildPid = $p.Id

            $lastSize = [long]0
            while (-not $p.HasExited) {
                if ($S.Stop) {
                    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
                    break
                }
                $cur = [long]0
                if ([System.IO.File]::Exists($dest)) { $cur = ([System.IO.FileInfo]::new($dest)).Length }
                if ($cur -gt $lastSize) { $lastSize = $cur; Touch }
                Set-Prog "Remux: $label" ($cur / $srcSize * 100)
                Start-Sleep -Milliseconds 400
            }
            $S.ChildPid = 0

            if ([System.IO.File]::Exists($tmpErr)) {
                $errTxt = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
                if ($errTxt) { Add-Content $log ("--- {0} ---`r`n{1}" -f $name, $errTxt) }
                Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
            }
            if ($S.Stop) { return $okAny }

            if ($p.ExitCode -eq 0 -and [System.IO.File]::Exists($dest) -and
                ([System.IO.FileInfo]::new($dest)).Length -gt 0) {
                $done = $true
            } else {
                Log 'Remux fehlgeschlagen (_ffmpeg.log), kopiere Original.' 'Yellow'
                if ([System.IO.File]::Exists($dest)) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $done) {
            $destOrig = Join-Path $Folder $name
            Log "Kopiere $name" 'Cyan'
            $done = Copy-FileWithProgress $f $destOrig $label
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
    if (-not $files) { Log "Keine Videodateien in $src gefunden." 'Red'; return $false }
    return (Rip-Files $files $Folder)
}

# --- Hauptverarbeitung pro Disc ---------------------------------------
function Process-Disc([string]$Drive) {
    Start-Sleep -Seconds 2

    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
    if (-not $disk -or $disk.DriveType -ne 5) { return }
    if (-not (Test-DriveReady $Drive)) { return }

    $label = $disk.VolumeName
    $S.DiscLabel = ('Disc: {0}  ({1})' -f $label, $Drive)
    Log "Disc erkannt in $Drive - Label: '$label'" 'Green'

    $isDVD  = Test-DiscDir "$Drive\VIDEO_TS"
    $isBD   = Test-DiscDir "$Drive\BDMV"
    $isVCD  = Test-DiscDir "$Drive\MPEGAV"
    $isSVCD = Test-DiscDir "$Drive\MPEG2"

    $ok = $false
    $folder = $null
    $S.State = 'Rippe...'
    $S.Ripping = $true
    $S.RipStart = Get-Date
    Touch

    try {
        if ($isDVD -or $isBD) {
            $folder = New-RipFolder $label
            Log "Zielordner: $folder"
            $ok = Rip-WithMakeMKV $Drive $folder
        }
        elseif ($isVCD -or $isSVCD) {
            $folder = New-RipFolder $label
            Log "Zielordner: $folder"
            $ok = Rip-VCD $Drive $folder $isSVCD
        }
        else {
            $videos = Find-VideoFiles $Drive
            if ($videos.Count -gt 0) {
                Log "Daten-Disc mit $($videos.Count) Videodatei(en) - Fallback-Modus." 'Cyan'
                $folder = New-RipFolder $label
                Log "Zielordner: $folder"
                $ok = Rip-Files $videos $folder
            }
            else {
                Log 'Keine Video-Disc und keine Videodateien gefunden - wird ignoriert.' 'Yellow'
                try {
                    $names = [System.IO.Directory]::GetFileSystemEntries("$Drive\") |
                             ForEach-Object { [System.IO.Path]::GetFileName($_) }
                    Log ('Root-Inhalt: ' + ($names -join ', ')) 'Yellow'
                } catch {
                    Log "Root nicht lesbar: $($_.Exception.Message)" 'Yellow'
                }
                return
            }
        }
    }
    finally {
        $S.Ripping = $false
        $S.Activity = ''; $S.Sub = ''; $S.Pct = 0
    }

    if ($S.Stop) { Log 'Rip abgebrochen.' 'Yellow'; return }

    if ($ok) {
        Log "Fertig: $folder" 'Green'
        if ($EjectWhenDone) { Eject-Disc $Drive; Log 'Disc ausgeworfen - naechste bitte.' 'Green' }
    } else {
        Log 'FEHLER beim Rippen - Details siehe Logdatei im Zielordner.' 'Red'
    }
}

# ============================ Watcher =================================
try {
    if (-not (Test-Path $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }

    $S.State = 'Warte auf Disc...'
    Log ('Watcher gestartet - Zielordner: {0}' -f $OutputRoot) 'Green'
    if ($MakeMKVCon) { Log "MakeMKV: $MakeMKVCon" } else { Log 'WARNUNG: makemkvcon.exe nicht gefunden!' 'Red' }

    $LastSig = @{}
    while (-not $S.Stop) {
        $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction SilentlyContinue
        foreach ($d in $drives) {
            if ($S.Stop) { break }
            $drive = $d.DeviceID

            if (-not (Test-DriveReady $drive)) {
                if ($LastSig.ContainsKey($drive)) {
                    $LastSig.Remove($drive)
                    Log "$drive leer - bereit fuer die naechste Disc."
                }
                continue
            }
            if (-not $d.VolumeSerialNumber) { continue }

            $sig = '{0}|{1}' -f $d.VolumeName, $d.VolumeSerialNumber
            if ($LastSig[$drive] -eq $sig) { continue }

            $LastSig[$drive] = $sig
            Process-Disc $drive
            if (-not $S.Stop) { $S.State = 'Warte auf Disc...' }
        }
        Sleep-Stop ($PollSeconds * 1000)
    }
}
catch {
    Log ("FATALER FEHLER im Worker: {0}" -f $_.Exception.Message) 'Red'
}
finally {
    $S.Ripping = $false
    $S.State = 'Gestoppt'
    Log 'Watcher beendet.' 'Yellow'
}
'@

# ======================================================================
#  UI-Aufbau
# ======================================================================
$xml    = [xml]$Xaml
$reader = New-Object System.Xml.XmlNodeReader $xml
$window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
'StateText','OutPath','BtnBrowse','MinLen','EjectBox','BtnOpen','BtnStart','BtnStop',
'DiscText','ActivityText','SubText','Bar','ProgText','LogList' |
    ForEach-Object { $ui[$_] = $window.FindName($_) }

# Farbpalette fuer Protokollzeilen
function New-Brush([string]$hex) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = New-Object Windows.Media.SolidColorBrush $c
    $b.Freeze(); return $b
}
$Brush = @{
    Gray   = New-Brush '#9a9aa3'
    Green  = New-Brush '#4ade80'
    Yellow = New-Brush '#facc15'
    Red    = New-Brush '#f87171'
    Cyan   = New-Brush '#7dd3fc'
}
$SpinnerChars = @('|','/','-','\')

# --- Einstellungen laden/speichern ------------------------------------
$SettingsPath = Join-Path $env:APPDATA 'AutoRip\settings.json'

function Load-Settings {
    $s = @{ OutputRoot = 'E:\Rips'; MinLength = 120; Eject = $true }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            if ($j.OutputRoot) { $s.OutputRoot = $j.OutputRoot }
            if ($null -ne $j.MinLength) { $s.MinLength = [int]$j.MinLength }
            if ($null -ne $j.Eject) { $s.Eject = [bool]$j.Eject }
        } catch {}
    }
    return $s
}
function Save-Settings {
    $dir = Split-Path $SettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @{
        OutputRoot = $ui.OutPath.Text
        MinLength  = [int]$ui.MinLen.Text
        Eject      = [bool]$ui.EjectBox.IsChecked
    } | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8
}

$cfg = Load-Settings
$ui.OutPath.Text        = $cfg.OutputRoot
$ui.MinLen.Text         = [string]$cfg.MinLength
$ui.EjectBox.IsChecked  = $cfg.Eject

# --- Worker-Verwaltung -------------------------------------------------
$script:Sync   = $null
$script:PSW    = $null
$script:RSW    = $null
$script:Handle = $null
$script:Tick   = 0

function Set-InputsEnabled([bool]$on) {
    $ui.OutPath.IsEnabled  = $on
    $ui.MinLen.IsEnabled   = $on
    $ui.EjectBox.IsEnabled = $on
    $ui.BtnBrowse.IsEnabled = $on
}

function Start-Worker {
    $minLen = 120
    if (-not [int]::TryParse($ui.MinLen.Text, [ref]$minLen)) { $minLen = 120; $ui.MinLen.Text = '120' }
    if ([string]::IsNullOrWhiteSpace($ui.OutPath.Text)) { $ui.OutPath.Text = 'E:\Rips' }
    Save-Settings

    $script:Sync = [hashtable]::Synchronized(@{
        Cfg          = @{ OutputRoot = $ui.OutPath.Text; MinLength = $minLen; Eject = [bool]$ui.EjectBox.IsChecked }
        Stop         = $false
        State        = 'Starte...'
        DiscLabel    = ''
        Activity     = ''
        Sub          = ''
        Pct          = [double]0
        Ripping      = $false
        RipStart     = (Get-Date)
        LastActivity = (Get-Date)
        ChildPid     = 0
        Log          = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    })

    $script:RSW = [runspacefactory]::CreateRunspace()
    $script:RSW.Open()
    $script:RSW.SessionStateProxy.SetVariable('S', $script:Sync)
    $script:PSW = [powershell]::Create()
    $script:PSW.Runspace = $script:RSW
    [void]$script:PSW.AddScript($WorkerScript)
    $script:Handle = $script:PSW.BeginInvoke()

    $ui.BtnStart.IsEnabled = $false
    $ui.BtnStop.IsEnabled  = $true
    Set-InputsEnabled $false
}

function Cleanup-Worker {
    if ($script:PSW) {
        try { if ($script:Handle) { [void]$script:PSW.EndInvoke($script:Handle) } } catch {}
        try { $script:PSW.Dispose() } catch {}
    }
    if ($script:RSW) {
        try { $script:RSW.Close(); $script:RSW.Dispose() } catch {}
    }
    $script:PSW = $null; $script:RSW = $null; $script:Handle = $null

    $ui.BtnStart.IsEnabled = $true
    $ui.BtnStop.IsEnabled  = $false
    Set-InputsEnabled $true
}

function Format-Time([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1) { return $ts.ToString('h\:mm\:ss') }
    return $ts.ToString('mm\:ss')
}

function Add-LogItem($entry) {
    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = ('[{0}] {1}' -f $entry.T.ToString('HH:mm:ss'), $entry.M)
    $b = $Brush[$entry.C]; if (-not $b) { $b = $Brush.Gray }
    $item.Foreground = $b
    [void]$ui.LogList.Items.Add($item)
    while ($ui.LogList.Items.Count -gt 400) { $ui.LogList.Items.RemoveAt(0) }
    $ui.LogList.ScrollIntoView($item)
}

# --- Button-Handler ----------------------------------------------------
$ui.BtnStart.Add_Click({ Start-Worker })

$ui.BtnStop.Add_Click({
    if ($script:Sync) {
        $script:Sync.Stop = $true
        $ui.BtnStop.IsEnabled = $false
        $ui.StateText.Text = 'Stoppe...'
    }
})

$ui.BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path $ui.OutPath.Text) { $dlg.SelectedPath = $ui.OutPath.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ui.OutPath.Text = $dlg.SelectedPath
    }
})

$ui.BtnOpen.Add_Click({
    $p = $ui.OutPath.Text
    if (Test-Path $p) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $p) }
})

# --- UI-Timer: zieht Status + Log aus $Sync ---------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $s = $script:Sync
    if (-not $s) { return }

    while ($s.Log.Count -gt 0) { Add-LogItem $s.Log.Dequeue() }

    $ui.StateText.Text    = $s.State
    $ui.DiscText.Text     = $s.DiscLabel
    $ui.ActivityText.Text = $s.Activity
    $ui.SubText.Text      = $s.Sub

    if ($s.Ripping) {
        $spin    = $SpinnerChars[$script:Tick % 4]; $script:Tick++
        $elapsed = (Get-Date) - $s.RipStart
        $pct     = [double]$s.Pct

        if ($pct -ge 0) {
            $ui.Bar.IsIndeterminate = $false
            $ui.Bar.Value = [math]::Max(0, [math]::Min(100, $pct))
            $pctTxt = ('{0:n1}%' -f $pct)
            if ($pct -gt 1 -and $pct -lt 100) {
                $remain = [TimeSpan]::FromSeconds([int]($elapsed.TotalSeconds / $pct * (100 - $pct)))
                $eta = 'Rest ~' + (Format-Time $remain)
            } else { $eta = 'Rest wird berechnet' }
        } else {
            $ui.Bar.IsIndeterminate = $true
            $pctTxt = '--%'
            $eta = 'Analysiere Disc'
        }

        $txt = ('{0}  {1}  |  {2} vergangen  |  {3}' -f $spin, $pctTxt, (Format-Time $elapsed), $eta)
        $silence = ((Get-Date) - $s.LastActivity).TotalSeconds
        if ($silence -ge 15) { $txt += ('  |  keine Ausgabe seit {0}s' -f [int]$silence) }
        $ui.ProgText.Text = $txt
    }
    else {
        $ui.Bar.IsIndeterminate = $false
        $ui.Bar.Value = 0
        $ui.ProgText.Text = 'Bereit.'
    }

    # Worker fertig? -> Ressourcen freigeben, Buttons zuruecksetzen
    if ($script:Handle -and $script:Handle.IsCompleted) {
        while ($s.Log.Count -gt 0) { Add-LogItem $s.Log.Dequeue() }
        $ui.StateText.Text = $s.State
        Cleanup-Worker
    }
})
$timer.Start()

# --- Fenster schliessen: Worker sauber beenden ------------------------
$window.Add_Closing({
    if ($script:Sync) {
        $script:Sync.Stop = $true
        if ($script:Sync.ChildPid -gt 0) {
            try { Stop-Process -Id $script:Sync.ChildPid -Force -ErrorAction SilentlyContinue } catch {}
        }
        Start-Sleep -Milliseconds 400
    }
    $timer.Stop()
    Cleanup-Worker
})

# Watcher direkt beim Programmstart loslegen lassen - wie die CLI-Version
Start-Worker

[void]$window.ShowDialog()
