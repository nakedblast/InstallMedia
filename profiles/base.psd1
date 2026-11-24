@{
    Name        = 'base'
    Description = 'Shared defaults for every machine: search debloat, bloat candidates, keyboard layouts.'

    # Search debloat. Apply = $false entries are kept for the record but never written.
    # SkipOnHome = $true: machine policy that Windows 11 Home ignores (not written on Home).
    # Verified: '<what it was checked against, date>', 'unverified' or 'ineffective on 24H2+'.
    # Local search history and the taskbar search box mode are deliberately not changed.
    SearchTweaks = @(
        @{
            Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'DWord'; Value = 1
            Apply = $true; SkipOnHome = $false; Verified = 'Win11 24H2/25H2 docs, 2026-11-24'
            Note = 'Removes web/Bing results and suggestions from Start search. Confidence high: 2025-2026 guides tested on 24H2/25H2 Home and Pro (anavem.com, makeuseof.com, windowsforum.com). Side effect: File Explorer search box stops showing recent-search suggestions.'
        }
        @{
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $false; Verified = 'Win11 24H2/25H2 docs, 2026-11-24'
            Note = 'Per-user Bing in search off. Confidence medium: not sufficient alone since 22H2, recommended together with DisableSearchBoxSuggestions for 24H2+ (makeuseof.com, winhelponline.com); harmless.'
        }
        @{
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $false; Verified = 'unverified'
            Note = 'Legacy Cortana consent flag. Confidence low that it still has an effect (Cortana app retired); still listed by 24H2-era guides (anonit.net 2025, woshub.com). Applied because it is harmless and per-user.'
        }
        @{
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDynamicSearchBoxEnabled'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $false; Verified = 'Win11 24H2/25H2 docs, 2026-11-24'
            Note = 'Settings > Privacy & security > Search permissions > Show search highlights = off. Confidence high (elevenforum.com, winhance.net; per-user, all editions).'
        }
        @{
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsMSACloudSearchEnabled'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $false; Verified = 'Win11 24H2/25H2 docs, 2026-11-24'
            Note = 'Settings toggle Cloud content search: Microsoft account = off (no OneDrive/Outlook cloud results in Start search). Confidence high (elevenforum.com, allthings.how).'
        }
        @{
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsAADCloudSearchEnabled'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $false; Verified = 'Win11 24H2/25H2 docs, 2026-11-24'
            Note = 'Settings toggle Cloud content search: work or school account = off. Confidence high (elevenforum.com, winhance.net); no effect without a work account.'
        }
        @{
            Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'EnableDynamicContentInWSB'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $true; Verified = 'Microsoft Learn Search Policy CSP, 2026-11-24'
            Note = 'Policy Allow search highlights = disabled. Confidence high: Microsoft Learn Policy CSP Search/AllowSearchHighlights, Pro/Enterprise/Education, Win11 22H2+. Not listed for Home.'
        }
        @{
            Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $true; Verified = 'Microsoft Learn Search Policy CSP, 2026-11-24'
            Note = 'Policy Do not search the web or display web results in Search. Confidence low on Pro: Microsoft Learn (Search/DoNotUseWebResults) lists Enterprise/Education only; harmless on Pro, effective on Enterprise/Education.'
        }
        @{
            Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; Type = 'DWord'; Value = 1
            Apply = $false; SkipOnHome = $true; Verified = 'ineffective on 24H2+'
            Note = 'Legacy policy Do not allow web search: broken since Windows 10 1803 (ghacks.net 2018) and absent from the current Microsoft Learn Search Policy CSP. Confidence medium. Not applied.'
        }
        @{
            Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCloudSearch'; Type = 'DWord'; Value = 0
            Apply = $true; SkipOnHome = $true; Verified = 'Microsoft Learn Search Policy CSP, 2026-11-24'
            Note = 'Policy Allow Cloud Search = disabled (machine-wide twin of the two cloud content toggles). Confidence high: Microsoft Learn Search/AllowCloudSearch, Pro/Enterprise/Education.'
        }
    )

    Bloat = @{
        Appx    = @(
            'Clipchamp.Clipchamp'
            '*McAfee*'
            'Microsoft.BingNews'
            'Microsoft.MicrosoftSolitaireCollection'
            'Microsoft.GamingApp'
            'Microsoft.XboxApp'
        )
        Win32   = @(
            'McAfee*'
            'Norton*'
            'ExpressVPN*'
            'WildTangent*'
            'Booking.com*'
            'Dropbox*promotion*'
        )
        Protect = @(
            '*ASUS*'
            '*MyASUS*'
            '*Armoury*'
            '*Realtek*'
            '*AMD*'
            '*Cirrus*'
            '*Dolby*'
            '*Synaptics*'
            '*ELAN*'
            'Microsoft.WindowsStore'
            'Microsoft.DesktopAppInstaller'
            'Microsoft.Office.*'
            '*Microsoft 365*'
        )
    }

    Keyboard = @{
        Ensure        = @('0409:00000409', '0419:00000419')
        Remove        = @('0409:00020409')
        LanguageOrder = @('en-US', 'ru-RU')
    }
}
