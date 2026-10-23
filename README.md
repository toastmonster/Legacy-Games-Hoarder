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
