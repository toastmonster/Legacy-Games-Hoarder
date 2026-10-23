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
.\legacy-games-downloader.ps1 -OutDir "D:\LegacyGamesBackup"
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

# Name lookup (best effort; falls back to product id if catalog entry not found)
$catalogNames = @{}
try {
    $catalog = Invoke-Api "/products/catalog"
    foreach ($c in $catalog.data) { $catalogNames["$($c.id)"] = $c.name }
} catch { Write-Warning "Couldn't load catalog names, will use product IDs for folder names." }

$i = 0
foreach ($d in $downloads) {
    $i++
    $label = $catalogNames["$($d.product_id)"]
    if (-not $label) { $label = "product_$($d.product_id)" }
    $safeName = ($label -replace '[\\/:*?"<>|]', '').Trim()
    $gameDir = Join-Path $OutDir $safeName
    New-Item -ItemType Directory -Force -Path $gameDir | Out-Null

    Write-Host "[$i/$($downloads.Count)] $label"
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            # Ask for a fresh link on every attempt: CDN links may be time-limited, so a resume needs a new one
            if ($d.giveaway) {
                $resp = Invoke-Api "/products/giveawaydownload?installerUuid=$($d.installer_uuid)" $userToken
            } else {
                $resp = Invoke-Api "/products/download?productId=$($d.product_id)&gameId=$($d.game_id)" $userToken
            }
            if ($resp.status -ne 'ok') { throw "API error: $($resp.data)" }
            $url = $resp.data.file
            if (-not $url) { throw "No download URL in response." }

            # Take only the leaf name and strip illegal characters so the server can't steer the save path
            $fileName = [uri]::UnescapeDataString(([uri]$url).Segments[-1])
            $fileName = (Split-Path -Leaf $fileName) -replace '[\\/:*?"<>|]', ''
            if (-not $fileName) { throw "Couldn't determine a safe file name from the download URL." }
            $dest = Join-Path $gameDir $fileName
            $part = "$dest.part"    # in-progress data lives here; only renamed to $dest once complete

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
            if ($attempt -lt $maxAttempts) {
                Write-Warning "  attempt $attempt failed: $($_.Exception.Message) Retrying in 5 s..."
                Start-Sleep -Seconds 5
            } else {
                Write-Warning "  FAILED: $($_.Exception.Message)"
            }
        }
    }
}

Write-Host "`nAll done. Installers are in: $OutDir"
