<#
.SYNOPSIS
Downloads the installer for every game on your Legacy Games account directly to a
folder you choose, instead of letting the launcher stash it in Temp and delete it.

.HOW IT WORKS
This calls the same api.legacygames.com endpoints the official launcher uses
(reverse-engineered from the launcher's own app.asar - not altered or bypassed),
using YOUR OWN login, then downloads the resulting CDN link straight to disk.
Your email/password are only used locally against legacygames.com's own login
endpoint and are never stored or sent anywhere else.

.USAGE
.\legacy-games-downloader.ps1 -OutDir "C:\LegacyGamesBackup"
(You'll be prompted for your Legacy Games email + password, or giveaway-only email.)
#>

param(
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
# The progress bar makes Invoke-WebRequest very slow for large files on Windows PowerShell 5.1
$ProgressPreference = 'SilentlyContinue'

$ApiBase = 'https://api.legacygames.com/v1'
$UserAgent = 'LegacyGamesLauncher/1.0.0'

function Invoke-Api($Path, $UserToken) {
    $headers = @{
        'Accept'        = 'application/json'
        'Content-Type'  = 'application/json'
        'Cache-Control' = 'no-cache'
        'Authorization' = '?token?'   # literal placeholder the official client sends
        'User-Agent'    = $UserAgent
    }
    if ($UserToken) { $headers['UserToken'] = $UserToken }
    $params = @{ Uri = "$ApiBase$Path"; Headers = $headers; Method = 'Get' }
    # PowerShell 6+ rejects the launcher's literal '?token?' Authorization value unless header validation is skipped
    if ($PSVersionTable.PSVersion.Major -ge 6) { $params['SkipHeaderValidation'] = $true }
    Invoke-RestMethod @params
}

# Returns the remote file size in bytes, or $null if the server won't say
function Get-RemoteSize($Url) {
    try {
        $h = (Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing).Headers['Content-Length']
        return [int64]@($h)[0]
    } catch { return $null }
}

# Minimal clean-up of a game name so it is a valid Windows folder name:
# ":" becomes " -" ("Law: Death" -> "Law - Death"), other forbidden characters are dropped
function ConvertTo-FolderName($Name) {
    $n = $Name -replace ':', ' -'
    $n = $n -replace '[\\/*?"<>|]', ''
    ($n -replace '\s{2,}', ' ').Trim().TrimEnd('.')
}

# Folder name for a library entry: the catalog's game_name for that product (matched by
# installer_uuid, then game_id, then the product's only game), else the product name, else product_<id>
function Get-GameFolderName($Entry) {
    $games = @($productGames["$($Entry.product_id)"])
    $name = $null
    if ($games.Count -gt 0) {
        $match = $null
        if ($Entry.installer_uuid) { $match = $games | Where-Object { $_.installer_uuid -eq $Entry.installer_uuid } | Select-Object -First 1 }
        if (-not $match -and $Entry.game_id) { $match = $games | Where-Object { $_.game_id -eq $Entry.game_id } | Select-Object -First 1 }
        if (-not $match -and $games.Count -eq 1) { $match = $games[0] }
        if ($match) { $name = $match.game_name }
    }
    if (-not $name) { $name = $productNames["$($Entry.product_id)"] }
    $folder = if ($name) { ConvertTo-FolderName $name } else { $null }
    if (-not $folder) { $folder = "product_$($Entry.product_id)" }
    $folder
}

# Builds a useful error string: the exception message plus the server's response body when there is one
function Get-ErrorDetail($ErrorRecord) {
    $msg = $ErrorRecord.Exception.Message
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message            # PowerShell 7
    } else {
        try {
            $resp = $ErrorRecord.Exception.Response
            if ($resp -and $resp.GetResponseStream) {        # Windows PowerShell 5.1
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
        } catch {}
    }
    if ($body) {
        $body = $body.Trim()
        if ($body.Length -gt 500) { $body = $body.Substring(0, 500) + '...' }
        return "$msg | Response body: $body"
    }
    return $msg
}

# curl.exe (built into Windows 10/11) handles resume and stall detection far better than Invoke-WebRequest
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curl) { Write-Warning "curl.exe not found; falling back to Invoke-WebRequest (no resume)." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$email = Read-Host 'Legacy Games account email'

Write-Host 'Checking account type...'
$pre = Invoke-Api "/users/isexistsbyemail?email=$([uri]::EscapeDataString($email))"
if ($pre.status -ne 'ok') { throw "Account lookup failed: $($pre.data)" }

$downloads = @()   # each: product_id, game_id, order_id, installer_uuid, giveaway(bool)

if ($pre.data.giveawayUser) {
    foreach ($g in $pre.data.giveawayUser.data) {
        $downloads += [pscustomobject]@{
            product_id = $g.product_id; game_id = $g.game_id
            order_id = $g.order_id; installer_uuid = $g.installer_uuid
            giveaway = $true
        }
    }
}

$userToken = $null
if ($pre.data.wpUser) {
    $securePw = Read-Host 'Legacy Games account password' -AsSecureString
    $plainPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($securePw))
    $userToken = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($email):$plainPw"))
    $plainPw = $null

    $login = Invoke-Api "/users/login" $userToken
    if ($login.status -ne 'ok') { throw "Login failed: $($login.data)" }
    $userId = $login.data.userId

    $owned = Invoke-Api "/users/downloads?userId=$userId" $userToken
    if ($owned.status -ne 'ok') { throw "Fetching library failed: $($owned.data)" }

    foreach ($d in $owned.data) {
        if ($d.order_id -and ($d.order_id.ToString()[0] -eq 'g')) { continue }   # already covered above
        $downloads += [pscustomobject]@{
            product_id = $d.product_id; game_id = $d.game_id
            order_id = $d.order_id; installer_uuid = $null
            giveaway = $false
        }
    }
}

$downloads = $downloads | Sort-Object -Property product_id, installer_uuid -Unique
Write-Host "Found $($downloads.Count) game(s)."

# Name lookup (best effort; falls back to product_<id> if the catalog can't be loaded)
$productNames = @{}
$productGames = @{}
try {
    $catalog = Invoke-Api "/products/catalog"
    # The catalog is a plain list of products; tolerate a {status, data} wrapper too
    $items = if ($catalog.PSObject.Properties['data']) { $catalog.data } else { $catalog }
    foreach ($c in $items) {
        $productNames["$($c.id)"] = $c.name
        $productGames["$($c.id)"] = if ($c.games) { @($c.games) } else { @() }
    }
    Write-Host "Loaded $($productNames.Count) catalog entries."
    if ($productNames.Count -eq 0) { Write-Warning "Catalog was empty; folders will be named product_<id>." }
} catch { Write-Warning "Couldn't load catalog names, will use product IDs for folder names. ($($_.Exception.Message))" }

$failures = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($d in $downloads) {
    $i++
    $label = Get-GameFolderName $d
    $gameDir = Join-Path $OutDir $label
    $oldDir = Join-Path $OutDir "product_$($d.product_id)"   # where earlier runs saved this product
    New-Item -ItemType Directory -Force -Path $gameDir | Out-Null

    Write-Host "[$i/$($downloads.Count)] $label"
    # If the library entry has no game_id, use the catalog's when the product lists exactly one game
    $gameId = $d.game_id
    if (-not $gameId -and -not $d.giveaway) {
        $catalogGames = @(@($productGames["$($d.product_id)"]) | Where-Object { $_ })
        if ($catalogGames.Count -eq 1) {
            $gameId = $catalogGames[0].game_id
            Write-Host "  library entry has no game_id; using the catalog's ($gameId)"
        }
    }

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $noRetry = $false
        $stage = 'requesting download link'
        try {
            # Ask for a fresh link on every attempt: CDN links may be time-limited, so a resume needs a new one
            if ($d.giveaway) {
                $apiPath = "/products/giveawaydownload?installerUuid=$($d.installer_uuid)"
            } else {
                $apiPath = "/products/download?productId=$($d.product_id)&gameId=$gameId"
            }
            $resp = Invoke-Api $apiPath $userToken
            if ($resp.status -ne 'ok') { $noRetry = $true; throw "API error: $($resp.data)" }
            $url = $resp.data.file
            if (-not $url) { $noRetry = $true; throw "No download URL in response." }
            $stage = 'downloading'

            # Take only the leaf name and strip illegal characters so the server can't steer the save path
            $fileName = [uri]::UnescapeDataString(([uri]$url).Segments[-1])
            $fileName = (Split-Path -Leaf $fileName) -replace '[\\/:*?"<>|]', ''
            if (-not $fileName) { $noRetry = $true; throw "Couldn't determine a safe file name from the download URL." }
            $dest = Join-Path $gameDir $fileName
            $part = "$dest.part"    # in-progress data lives here; only renamed to $dest once complete

            # Pick up files saved by an earlier run in product_<id>\ and move them into the named folder
            if ($oldDir -ne $gameDir) {
                $oldFile = Join-Path $oldDir $fileName
                foreach ($suffix in '', '.part', '.source.txt') {
                    if ((Test-Path "$oldFile$suffix") -and -not (Test-Path "$dest$suffix")) {
                        Move-Item -Path "$oldFile$suffix" -Destination "$dest$suffix"
                    }
                }
            }

            $remoteSize = Get-RemoteSize $url
            if ((Test-Path $dest) -and $remoteSize -and ((Get-Item $dest).Length -eq $remoteSize)) {
                Write-Host "  already downloaded, skipping."
                if (-not (Test-Path "$dest.source.txt")) { Set-Content -Path "$dest.source.txt" -Value $url -Encoding UTF8 }
                break
            }

            if ($attempt -eq 1) { Write-Host "  downloading to $dest ..." }
            else { Write-Host "  resuming (attempt $attempt of $maxAttempts) ..." }

            if ($curl) {
                # -C - resumes the .part file; the speed options abort a connection that stalls
                # (under 1 KB/s for 60 s) so the retry loop can pick it up again
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                & curl.exe -L --fail --progress-bar -C - --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o $part $url
                $code = $LASTEXITCODE
                $ErrorActionPreference = $prevEap
                if ($code -eq 33) {
                    Remove-Item $part -Force -ErrorAction SilentlyContinue
                    throw "Server refused to resume; restarting from the beginning."
                }
                if ($code -ne 0) { throw "curl exited with code $code" }
            } else {
                Invoke-WebRequest -Uri $url -OutFile $part
            }

            if ($remoteSize -and ((Get-Item $part).Length -ne $remoteSize)) {
                throw "Size mismatch (got $((Get-Item $part).Length) of $remoteSize bytes)."
            }
            Move-Item -Force -Path $part -Destination $dest
            Set-Content -Path "$dest.source.txt" -Value $url -Encoding UTF8   # record where it came from
            Write-Host "  done."
            break
        } catch {
            $err = $_
            $detail = Get-ErrorDetail $err
            $status = $null
            try { if ($err.Exception.Response) { $status = [int]$err.Exception.Response.StatusCode } } catch {}
            # A 4xx from the server (other than timeout / rate limit) won't fix itself, so don't retry it
            if ($status -ge 400 -and $status -lt 500 -and $status -notin 408, 429) { $noRetry = $true }

            if (-not $noRetry -and $attempt -lt $maxAttempts) {
                Write-Warning "  attempt $attempt failed ($stage): $detail Retrying in 5 s..."
                Start-Sleep -Seconds 5
            } else {
                $info = "$label | product_id=$($d.product_id) game_id=$gameId order_id=$($d.order_id) installer_uuid=$($d.installer_uuid) giveaway=$($d.giveaway) | stage: $stage | request: GET $apiPath | $detail"
                Write-Warning "  FAILED: $info"
                $failures.Add([pscustomobject]@{ Game = $label; Detail = $info })
                if ((Test-Path $gameDir) -and -not (Get-ChildItem -Path $gameDir -Force)) { Remove-Item -Path $gameDir }
                break
            }
        }
    }
}

if ($failures.Count -gt 0) {
    $logPath = Join-Path $OutDir 'download-failures.txt'
    $failures | ForEach-Object { $_.Detail } | Set-Content -Path $logPath -Encoding UTF8
    Write-Warning "$($failures.Count) game(s) failed:"
    $failures | ForEach-Object { Write-Host "  - $($_.Game)" }
    Write-Host "Full details saved to: $logPath"
}

# Remove empty product_<id> folders left over from earlier runs (folders with anything in them are never touched)
Get-ChildItem -Path $OutDir -Directory -Filter 'product_*' |
    Where-Object { -not (Get-ChildItem -Path $_.FullName -Force) } |
    Remove-Item

Write-Host "`nAll done. Installers are in: $OutDir"
