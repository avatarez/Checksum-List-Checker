<# :batBegin
@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
set "BATFILE=%~f0"
set "BATDIR=%~dp0"
set BATARGS=%*
powershell -NoProfile -Command "& ([scriptblock]::Create([System.IO.File]::ReadAllText($env:BATFILE, [System.Text.Encoding]::UTF8)))"
exit /b %ERRORLEVEL%
:batEnd #>

enum TimeUnit {
	Minutes
	Hours
	Days
	Months
	Years
}

enum VerifyMode {
	No
	All
	Paths
}

enum MenuMode {
	Entries
	Hashes
}

$script:options = [PSCustomObject]@{
	ShowMenu = $true
	DuplicateEntries = $true
	MissingFiles = $true
	MissingEntries = $true
	VerifyHash = [VerifyMode]::No
	EntMask = $null
	EntMaskInclude = $true
	EntTimeUnit = $null
	EntTimeValue = 0
	HashMask = $null
	HashMaskInclude = $true
	HashTimeUnit = $null
	HashTimeValue = 0
	HashVerbose = $false
	AbsPaths = $false
	SysResolution = $true
	Update = $false
	UpdateMsg = $true
	SafeUpdate = $false
	Log = $false
	LogMsg = $true
	NoAuto = $false
	Quiet = $false
}

$script:stats = [PSCustomObject]@{
	FilesChecked = 0
	FilesCheckedErr = 0
	FilesNotChecked = 0
	FilesUpdated = 0
	FilesUpdatedErr = 0
	FilesNotUpdated = 0
	EntriesChecked = 0
	EntriesNotFound = 0
	LinesSkipped = 0
	DuplicateEntries = 0
	MissingEntries = 0
	MissingFiles = 0
	HashesCalculated = 0
	HashesNotCalculated = 0
	HashMismatches = 0
	SearchErr = 0
	CurrentSearchErr = 0
	FilesNotFound = 0
	CurrentFilesNotFound = 0
	EntriesDeleted = 0
	EntriesUpdated = 0
	HashesAdded = 0
	HashesNotAdded = 0
}

$script:fileAlgorithms = @{
	'.sfv' = 'CRC32'
	'.md5' = 'MD5'
	'.sha1' = 'SHA1'
	'.sha256' = 'SHA256'
	'.sha384' = 'SHA384'
	'.sha512' = 'SHA512'
}

$script:checkFiles = @()
$script:checkPaths = @()
$script:auto = $true
$script:logList = [System.Collections.Generic.List[string]]::new()
$script:ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage, [System.Text.EncoderExceptionFallback]::new(), [System.Text.DecoderExceptionFallback]::new())
$script:utf = [System.Text.UTF8Encoding]::new($false, $true)
$script:regexPathSep = [regex]::new('\\{2,}', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Show-MainMenu {
	$restart = $true
	while ($restart) {
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:checkFiles.Count -eq 1) {
			Write-Host ('Checksum file: ' + (Remove-LongPrefix $script:checkFiles[0].FullName))
		} elseif ($script:checkFiles.Count -gt 0) {
			Write-Host ('Checksum files: ' + $script:checkFiles.Count)
		} else {
			Write-Host 'Checksum files: None' -ForegroundColor Red
		}
		if ($script:auto) {
			if ($script:options.NoAuto) {
				Write-Host 'Search paths: None'
			} else {
				Write-Host 'Search paths: Auto'
			}
		} elseif ($script:checkPaths.Count -eq 1) {
			Write-Host ('Search path: ' + (Remove-LongPrefix $script:checkPaths[0]))
		} else {
			Write-Host ('Search paths: ' + $script:checkPaths.Count)
		}
		Write-Host ''
		if ($script:checkFiles.Count -gt 0) {
			Write-Host '1.  [Start check]' -ForegroundColor Green
		} else {
			Write-Host '1.  [Start check]' -ForegroundColor DarkGreen
		}
		Write-Host ''
		if ($script:options.DuplicateEntries) {
			Write-Host '2.  Check for ' -NoNewline
			Write-Host 'duplicate entries' -ForegroundColor Cyan -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '2.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'duplicate entries' -ForegroundColor DarkCyan -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:options.MissingFiles) {
			Write-Host '3.  Check for ' -NoNewline
			Write-Host 'missing files' -ForegroundColor Magenta -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '3.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing files' -ForegroundColor DarkMagenta -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:auto -and $script:options.NoAuto) {
			Write-Host '4.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing entries' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Not available' -ForegroundColor DarkGray
		} elseif ($script:options.MissingEntries) {
			Write-Host '4.  Check for ' -NoNewline
			Write-Host 'missing entries' -ForegroundColor Yellow -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '4.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing entries' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:options.VerifyHash -eq [VerifyMode]::All) {
			Write-Host '5.  Verify ' -NoNewline
			Write-Host 'hashes' -ForegroundColor Red -NoNewline
			Write-Host ' (slow): All'
		} elseif ($script:options.VerifyHash -eq [VerifyMode]::Paths) {
			Write-Host '5.  Verify ' -NoNewline
			Write-Host 'hashes' -ForegroundColor Red -NoNewline
			Write-Host ' (slow): Search paths'
		} else {
			Write-Host '5.  Verify ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'hashes' -ForegroundColor DarkRed -NoNewline
			Write-Host ' (slow): No' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:options.MissingEntries) {
			if ([string]::IsNullOrEmpty($script:options.EntMask)) {
				Write-Host '6.  Check missing entries by mask: None' -ForegroundColor DarkGray
			} elseif ($script:options.EntMaskInclude) {
				Write-Host ('6.  Check missing entries by mask (include): ' + $script:options.EntMask)
			} else {
				Write-Host ('6.  Check missing entries by mask (exclude): ' + $script:options.EntMask)
			}
		} else {
			Write-Host '6.  Check missing entries by mask: Not available' -ForegroundColor DarkGray
		}
		if ($script:options.MissingEntries) {
			if ($script:options.EntTimeValue -gt 0) {
				Write-Host ('7.  Check missing entries by last write time (' + (Get-TimeUnit $script:options.EntTimeUnit) + '): ' + $script:options.EntTimeValue)
			} else {
				Write-Host '7.  Check missing entries by last write time: None' -ForegroundColor DarkGray
			}
		} else {
			Write-Host '7.  Check missing entries by last write time: Not available' -ForegroundColor DarkGray
		}
		if ($script:options.VerifyHash -ne [VerifyMode]::No) {
			if ([string]::IsNullOrEmpty($script:options.HashMask)) {
				Write-Host '8.  Verify hashes by mask: None' -ForegroundColor DarkGray
			} elseif ($script:options.HashMaskInclude) {
				Write-Host ('8.  Verify hashes by mask (include): ' + $script:options.HashMask)
			} else {
				Write-Host ('8.  Verify hashes by mask (exclude): ' + $script:options.HashMask)
			}
		} else {
			Write-Host '8.  Verify hashes by mask: Not available' -ForegroundColor DarkGray
		}
		if ($script:options.VerifyHash -ne [VerifyMode]::No) {
			if ($script:options.HashTimeValue -gt 0) {
				Write-Host ('9.  Verify hashes by last write time (' + (Get-TimeUnit $script:options.HashTimeUnit) + '): ' + $script:options.HashTimeValue)
			} else {
				Write-Host '9.  Verify hashes by last write time: None' -ForegroundColor DarkGray
			}
		} else {
			Write-Host '9.  Verify hashes by last write time: Not available' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:options.HashVerbose) {
			Write-Host '10. Verbose ' -NoNewline
			Write-Host 'hash' -ForegroundColor Green -NoNewline
			Write-Host ' verification mode: Yes'
		} else {
			Write-Host '10. Verbose ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'hash' -ForegroundColor DarkGreen -NoNewline
			Write-Host ' verification mode: No' -ForegroundColor DarkGray
		}
		if ($script:options.MissingEntries) {
			if ($script:options.AbsPaths) {
				Write-Host '11. Missing entries path mode: Absolute'
			} else {
				Write-Host '11. Missing entries path mode: Relative'
			}
		} else {
			Write-Host '11. Missing entries path mode: Not available' -ForegroundColor DarkGray
		}
		if ($script:options.SysResolution) {
			Write-Host '12. Path resolution mode: System'
		} else {
			Write-Host '12. Path resolution mode: Internal'
		}
		Write-Host ''
		Write-Host '13. View checksum files and search paths'
		Write-Host ''
		Write-Host '0.  Exit'
		Write-Host ''
		$readValue = Read-Host 'Select option (0-13)'
		switch ($readValue.Trim()) {
			'' {
				$restart = $script:checkFiles.Count -eq 0
				break
			}
			'1' {
				$restart = $script:checkFiles.Count -eq 0
				break
			}
			'2' {
				$script:options.DuplicateEntries = -not $script:options.DuplicateEntries
				break
			}
			'3' {
				$script:options.MissingFiles = -not $script:options.MissingFiles
				break
			}
			'4' {
				if (-not ($script:auto -and $script:options.NoAuto)) { $script:options.MissingEntries = -not $script:options.MissingEntries }
				break
			}
			'5' {
				if ($script:options.VerifyHash -eq [VerifyMode]::All) {
					if ($script:auto -and $script:options.NoAuto) {
						$script:options.VerifyHash = [VerifyMode]::No
					} else {
						$script:options.VerifyHash = [VerifyMode]::Paths
					}
				} elseif ($script:options.VerifyHash -eq [VerifyMode]::Paths) {
					$script:options.VerifyHash = [VerifyMode]::No
				} else {
					$script:options.VerifyHash = [VerifyMode]::All
				}
				break
			}
			'6' {
				if ($script:options.MissingEntries) { Show-MaskMenu ([MenuMode]::Entries) }
				break
			}
			'7' {
				if ($script:options.MissingEntries) { Show-TimeMenu ([MenuMode]::Entries) }
				break
			}
			'8' {
				if ($script:options.VerifyHash -ne [VerifyMode]::No) { Show-MaskMenu ([MenuMode]::Hashes) }
				break
			}
			'9' {
				if ($script:options.VerifyHash -ne [VerifyMode]::No) { Show-TimeMenu ([MenuMode]::Hashes) }
				break
			}
			'10' {
				$script:options.HashVerbose = -not $script:options.HashVerbose
				break
			}
			'11' {
				if ($script:options.MissingEntries) { $script:options.AbsPaths = -not $script:options.AbsPaths }
				break
			}
			'12' {
				$script:options.SysResolution = -not $script:options.SysResolution
				break
			}
			'13' {
				Show-PathList
				break
			}
			'0' {
				exit 0
			}
		}
	}
}

function Show-MaskMenu {
	param(
		[MenuMode]$menuMode
	)
	$menuMaskInclude = $true
	$menuMaskValue = $null
	try {
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		Write-Host '1. Include'
		Write-Host '2. Exclude'
		Write-Host ''
		$readValue = Read-Host 'Select mask mode (1-2)'
		switch ($readValue.Trim()) {
			'1' {
				Write-Host ''
				$menuMaskValue = Read-Host 'Include mask'
				break
			}
			'2' {
				$menuMaskInclude = $false
				Write-Host ''
				$menuMaskValue = Read-Host 'Exclude mask'
				break
			}
			default { throw }
		}
		if ([string]::IsNullOrEmpty($menuMaskValue)) { throw }
	} catch {
		$menuMaskInclude = $true
		$menuMaskValue = $null
	}
	switch ($menuMode) {
		([MenuMode]::Entries) {
			$script:options.EntMaskInclude = $menuMaskInclude
			$script:options.EntMask = $menuMaskValue
			break
		}
		([MenuMode]::Hashes) {
			$script:options.HashMaskInclude = $menuMaskInclude
			$script:options.HashMask = $menuMaskValue
			break
		}
	}
}

function Show-TimeMenu {
	param(
		[MenuMode]$menuMode
	)
	$menuTimeUnit = $null
	$menuTimeValue = 0
	try {
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		Write-Host '1. Minutes'
		Write-Host '2. Hours'
		Write-Host '3. Days'
		Write-Host '4. Months'
		Write-Host '5. Years'
		Write-Host ''
		$readValue = Read-Host 'Select time unit (1-5)'
		switch ($readValue.Trim()) {
			'1' {
				$menuTimeUnit = [TimeUnit]::Minutes
				break
			}
			'2' {
				$menuTimeUnit = [TimeUnit]::Hours
				break
			}
			'3' {
				$menuTimeUnit = [TimeUnit]::Days
				break
			}
			'4' {
				$menuTimeUnit = [TimeUnit]::Months
				break
			}
			'5' {
				$menuTimeUnit = [TimeUnit]::Years
				break
			}
			default { throw }
		}
		Write-Host ''
		$timeValue = Read-Host ('Time since last file write: (' + (Get-TimeUnit $menuTimeUnit) + ')')
		$menuTimeValue = [int]$timeValue
		if ($menuTimeValue -le 0) { throw }
	} catch {
		$menuTimeUnit = $null
		$menuTimeValue = 0
	}
	switch ($menuMode) {
		([MenuMode]::Entries) {
			$script:options.EntTimeUnit = $menuTimeUnit
			$script:options.EntTimeValue = $menuTimeValue
			break
		}
		([MenuMode]::Hashes) {
			$script:options.HashTimeUnit = $menuTimeUnit
			$script:options.HashTimeValue = $menuTimeValue
			break
		}
	}
}

function Show-PathList {
	$restart = $true
	while ($restart) {
		$restart = $false
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:checkFiles.Count -eq 0) {
			Show-NewPathList
			if ($script:checkFiles.Count -eq 0) {
				return
			} else {
				$restart = $true
				continue
			}
		}
		if ($script:auto -and (-not $script:options.NoAuto)) {
			foreach ($file in $script:checkFiles) {
				Write-Host ('Checksum file: ' + (Remove-LongPrefix $file.FullName))
				$fileDir = $file.DirectoryName
				$fileBaseNameDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
				if ([System.IO.Directory]::Exists($fileBaseNameDir)) {
					Write-Host ('Search path: ' + (Remove-LongPrefix $fileBaseNameDir))
				} else {
					Write-Host ('Search path: ' + (Remove-LongPrefix $fileDir))
				}
				Write-Host ''
			}
		} else {
			if ($script:checkFiles.Count -eq 1) {
				Write-Host ('Checksum file: ' + (Remove-LongPrefix $script:checkFiles[0].FullName))
			} else {
				Write-Host 'Checksum files:'
				foreach ($file in $script:checkFiles) {
					Write-Host (Remove-LongPrefix $file.FullName)
				}
			}
			Write-Host ''
			if ($script:auto -and $script:options.NoAuto) {
				Write-Host 'Search paths: None'
			} else {
				if ($script:checkPaths.Count -eq 1) {
					Write-Host ('Search path: ' + (Remove-LongPrefix $script:checkPaths[0]))
				} else {
					Write-Host 'Search paths:'
					foreach ($path in $script:checkPaths) {
						Write-Host (Remove-LongPrefix $path)
					}
				}
			}
			Write-Host ''
		}
		$msg = $true
		while ($msg) {
			Write-Host 'Set new list? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$readValue = Read-Host ')'
			switch -Regex ($readValue.Trim()) {
				'^$' {
					$msg = $false
					break
				}
				'^(y|yes)$' {
					Write-Host ''
					Show-NewPathList
					if ($script:checkFiles.Count -eq 0) { return }
					$restart = $true
					$msg = $false
					break
				}
				'^(n|no)$' {
					$msg = $false
					break
				}
			}
		}
	}
}

function Show-NewPathList {
	$readValue = Read-Host 'Checksum files'
	if (-not [string]::IsNullOrEmpty($readValue)) { Parse-Arguments $readValue -Files }
	Write-Host ''
	$readValue = Read-Host 'Search paths'
	if ([string]::IsNullOrEmpty($readValue)) {
		if (-not $script:auto) {
			$msg = $true
			while ($msg) {
				Write-Host ''
				Write-Host 'Reset search paths? (Yes / ' -NoNewline
				Write-Host '[No]' -ForegroundColor Green -NoNewline
				$readValue = Read-Host ')'
				switch -Regex ($readValue.Trim()) {
					'^$' {
						$msg = $false
						break
					}
					'^(y|yes)$' {
						$script:checkPaths = @()
						$script:auto = $true
						$msg = $false
						break
					}
					'^(n|no)$' {
						$msg = $false
						break
					}
				}
			}
		}
	} else {
		Parse-Arguments $readValue -Paths
		$script:auto = $script:checkPaths.Count -eq 0
	}
	if ($script:auto -and $script:options.NoAuto) {
		$script:options.MissingEntries = $false
		if ($script:options.VerifyHash -eq [VerifyMode]::Paths) { $script:options.VerifyHash = [VerifyMode]::No }
	}
}

function Parse-Arguments {
	param(
		[string]$Arguments,
		[switch]$Files,
		[switch]$Paths
	)
	$argList = @([regex]::Matches($Arguments, '(?:[^\s"]|"[^"]*")+') | ForEach-Object { $_.Value })
	if ($argList.Count -eq 0) { return }
	$fileArgs = [ordered]@{}
	$pathArgs = [ordered]@{}
	$pathSep = $Paths
	foreach ($argRaw in $argList) {
		$arg = $argRaw.Replace('"', '')
		if ((-not $pathSep) -and (-not $Files)) {
			$argOptions = @()
			$argValue = $null
			if ($arg -eq '--') {
				$pathSep = $true
				continue
			} elseif ($arg -match '^(--[^=]+=)(.*)$') {
				$argOptions = @($Matches[1])
				$argValue = $Matches[2]
			} elseif ($arg -match '^--.+$') {
				$argOptions = @($arg)
			} elseif ($arg -match '^-(.+)$') {
				$argOptions = @($Matches[1].ToCharArray() | ForEach-Object { '-' + $_ })
			}
			if ($argOptions.Count -gt 0) {
				try {
					foreach ($opt in $argOptions) {
						switch -Regex ($opt) {
							'^(-c|--check)$' {
								$script:options.Update = $false
								$script:options.ShowMenu = $false
								$script:options.UpdateMsg = $false
								$script:options.LogMsg = $false
								break
							}
							'^(-u|--update)$' {
								$script:options.Update = $true
								$script:options.ShowMenu = $false
								$script:options.UpdateMsg = $false
								$script:options.LogMsg = $false
								break
							}
							'^(-s|--safe-update)$' {
								$script:options.SafeUpdate = $true
								$script:options.Update = $true
								$script:options.ShowMenu = $false
								$script:options.UpdateMsg = $false
								$script:options.LogMsg = $false
								break
							}
							'^(-d|--skip-duplicates)$' {
								$script:options.DuplicateEntries = $false
								break
							}
							'^(-f|--skip-missing-files)$' {
								$script:options.MissingFiles = $false
								break
							}
							'^(-e|--skip-missing-entries)$' {
								$script:options.MissingEntries = $false
								break
							}
							'^(-h|--verify-all-hashes)$' {
								$script:options.VerifyHash = [VerifyMode]::All
								break
							}
							'^(-p|--verify-paths-hashes)$' {
								$script:options.VerifyHash = [VerifyMode]::Paths
								break
							}
							'^(-v|--verbose-hashes)$' {
								$script:options.HashVerbose = $true
								break
							}
							'^(-a|--absolute-paths)$' {
								$script:options.AbsPaths = $true
								break
							}
							'^(-i|--internal-resolution)$' {
								$script:options.SysResolution = $false
								break
							}
							'^(-l|--save-log)$' {
								$script:options.LogMsg = $false
								$script:options.Log = $true
								break
							}
							'^(-n|--no-auto)$' {
								$script:options.NoAuto = $true
								break
							}
							'^(-q|--quiet)$' {
								$script:options.ShowMenu = $false
								$script:options.UpdateMsg = $false
								$script:options.LogMsg = $false
								$script:options.Quiet = $true
								break
							}
							'^--entries-include=$' {
								if ([string]::IsNullOrEmpty($argValue)) { throw }
								$script:options.EntMask = $argValue
								$script:options.EntMaskInclude = $true
								$script:options.MissingEntries = $true
								break
							}
							'^--entries-exclude=$' {
								if ([string]::IsNullOrEmpty($argValue)) { throw }
								$script:options.EntMask = $argValue
								$script:options.EntMaskInclude = $false
								$script:options.MissingEntries = $true
								break
							}
							'^--entries-time-minutes=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Minutes
								$script:options.MissingEntries = $true
								break
							}
							'^--entries-time-hours=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Hours
								$script:options.MissingEntries = $true
								break
							}
							'^--entries-time-days=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Days
								$script:options.MissingEntries = $true
								break
							}
							'^--entries-time-months=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Months
								$script:options.MissingEntries = $true
								break
							}
							'^--entries-time-years=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Years
								$script:options.MissingEntries = $true
								break
							}
							'^--hashes-include=$' {
								if ([string]::IsNullOrEmpty($argValue)) { throw }
								$script:options.HashMask = $argValue
								$script:options.HashMaskInclude = $true
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							'^--hashes-exclude=$' {
								if ([string]::IsNullOrEmpty($argValue)) { throw }
								$script:options.HashMask = $argValue
								$script:options.HashMaskInclude = $false
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							'^--hashes-time-minutes=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Minutes
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							'^--hashes-time-hours=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Hours
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							'^--hashes-time-days=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Days
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							'^--hashes-time-months=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Months
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							'^--hashes-time-years=$' {
								$intValue = [int]$argValue
								if ($intValue -le 0) { throw }
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Years
								if ($script:options.VerifyHash -eq [VerifyMode]::No) { $script:options.VerifyHash = [VerifyMode]::All }
								break
							}
							default { throw }
						}
					}
				} catch {
					Start-Clear
					Write-Host 'Syntax error!' -ForegroundColor Red
					Write-Host ('Invalid option: ' + $argRaw) -ForegroundColor Red
					Start-Pause
					exit 2000
				}
				continue
			}
		}
		if ((Remove-LongPrefix $arg) -match '[*?]') {
			try {
				$argName = [System.IO.Path]::GetFileName($arg)
				$argDir = [System.IO.Path]::GetDirectoryName($arg)
				if (-not $argDir) {
					$argDir = ([System.IO.Directory]::GetCurrentDirectory())
				}
				$argDir = Get-LongPath $argDir
			} catch {
				continue
			}
			$argObjects = @(Get-ChildItem -LiteralPath $argDir -Filter $argName -Force -ErrorAction SilentlyContinue)
		} else {
			try { $argName = Get-LongPath $arg } catch { continue }
			$argObjects = @(Get-Item -LiteralPath $argName -Force -ErrorAction SilentlyContinue)
		}
		foreach ($argObj in $argObjects) {
			$argName = Add-LongPrefix $argObj.FullName
			if ($argObj.PSIsContainer) {
				if ((-not $pathArgs.Contains($argName)) -and (-not $Files)) {
					$pathArgs[$argName] = $null
				}
			} else {
				if ((-not $pathSep) -and ($script:fileAlgorithms.ContainsKey($argObj.Extension))) {
					if (-not $fileArgs.Contains($argName)) { $fileArgs[$argName] = $argObj }
				} elseif ((-not $pathArgs.Contains($argName)) -and (-not $Files)) {
					$pathArgs[$argName] = $null
				}
			}
		}
	}
	if ($fileArgs.Count -gt 0) { $script:checkFiles = @($fileArgs.Values) }
	if ($pathArgs.Count -gt 0) { $script:checkPaths = @($pathArgs.Keys) }
}

function Add-LongPrefix {
	param(
		[string]$Path
	)
	if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
		return $Path
	} elseif ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
		return $Path
	} elseif ($Path.StartsWith('\\.\', [System.StringComparison]::Ordinal)) {
		return $Path
	} elseif ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) {
		return '\\?\UNC\' + $Path.Substring(2)
	} else {
		return '\\?\' + $Path
	}
}

function Remove-LongPrefix {
	param(
		[string]$Path
	)
	if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
		return '\\' + $Path.Substring(8)
	} elseif ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
		return $Path.Substring(4)
	} elseif ($Path.StartsWith('\\.\', [System.StringComparison]::Ordinal)) {
		return $Path.Substring(4)
	} else {
		return $Path
	}
}

function Get-LongPath {
	param(
		[string]$Path
	)
	if ($script:options.SysResolution) {
		return Add-LongPrefix ([System.IO.Path]::GetFullPath((Remove-LongPrefix $Path)))
	}
	$normal = (Remove-LongPrefix $Path).Replace('/', '\')
	$unc = $normal.StartsWith('\\', [System.StringComparison]::Ordinal)
	$normal = $script:regexPathSep.Replace($normal, '\')
	if ($unc) { $normal = '\' + $normal }
	$root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($normal))
	if ($normal -ieq $root) {
		return Add-LongPrefix $root
	}
	$root = $root.TrimEnd('\') + '\'
	$rootLen = $root.Length
	if ($normal.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
		$relative = $normal.Substring($rootLen).TrimStart('\')
	} elseif ($normal.StartsWith($root.Substring(0, 2), [System.StringComparison]::OrdinalIgnoreCase)) {
		$current = [System.IO.Path]::GetFullPath($root.Substring(0, 2) + '.')
		$relative = ([System.IO.Path]::Combine($current,$normal.Substring(2))).Substring($rootLen).TrimStart('\')
	} elseif ($normal.StartsWith('\', [System.StringComparison]::Ordinal)) {
		$relative = $normal.TrimStart('\')
	} else {
		$current = [System.IO.Directory]::GetCurrentDirectory()
		$relative = ([System.IO.Path]::Combine($current, $normal)).Substring($rootLen).TrimStart('\')
	}
	if ([string]::IsNullOrEmpty($relative)) {
		return Add-LongPrefix $root
	}
	$pathBuilder = [System.Text.StringBuilder]::new()
	$segmentBuilder = [System.Text.StringBuilder]::new()
	$chars = $relative.ToCharArray()
	$skip = 0
	$idx = $chars.Length - 1
	while ($idx -ge 0) {
		$pathSep = $false
		$chr = $chars[$idx]
		if ($chr -eq [char]'\') {
			$pathSep = $true
		} else {
			[void]$segmentBuilder.Append($chr)
		}
		if ($pathSep -or ($idx -eq 0)) {
			if ($segmentBuilder.Length -gt 0) {
				$segment = $segmentBuilder.ToString()
				if ($segment -ne '.') {
					if ($segment -eq '..') {
						$skip++
					} elseif ($skip -gt 0) {
						$skip--
					} else {
						[void]$pathBuilder.Append($segment)
						if ($pathSep) { [void]$pathBuilder.Append([char]'\') }
					}
				}
				[void]$segmentBuilder.Clear()
			}
		}
		$idx--
	}
	$chars = $pathBuilder.ToString().ToCharArray()
	[Array]::Reverse($chars)
	$relative = -join $chars
	return Add-LongPrefix ([System.IO.Path]::Combine($root, $relative.TrimStart('\')))
}

function Get-Encoding {
	param(
		[string]$Path
	)
	$reader = $null
	try {
		$reader = [System.IO.StreamReader]::new($Path, $script:utf, $true)
		[void]$reader.ReadToEnd()
		return $reader.CurrentEncoding
	} catch {
		return $script:ansi
	} finally {
		if ($reader) { $reader.Dispose() }
	}
}

function Get-HashValue {
	param(
		[string]$Path,
		[string]$Algorithm
	)
	$stream = $null
	try {
		try {
			$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
		} catch {
			try {
				$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
			} catch {
				return $null
			}
		}
		if ($Algorithm -ieq 'CRC32') {
			$result = [System.UInt32]0
			$buffer = [byte[]]::new(65536)
			while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
				$result = [NTDLL.Win32Crc32]::RtlComputeCrc32($result, $buffer, $bytesRead)
			}
			return $result.ToString('X8')
		} else {
			return (Get-FileHash -InputStream $stream -Algorithm $Algorithm -ErrorAction Stop).Hash.ToLowerInvariant()
		}
	} catch {
		return $null
	} finally {
		if ($stream) { $stream.Dispose() }
	}
}

function Get-EntLine {
	param(
		[string]$Path,
		[string]$Hash,
		[string]$Algorithm
	)
	if ($Algorithm -ine 'CRC32') {
		return $Hash + ' *' + $Path
	} elseif ($Path.TrimStart().StartsWith(';', [System.StringComparison]::Ordinal)) {
		return '.\' + $Path + ' ' + $Hash
	} else {
		return $Path + ' ' + $Hash
	}
}

function Get-NewFiles {
	param(
		[string[]]$Paths
	)
	$newFiles = [ordered]@{}
	$searchErrors = @()
	$script:stats.CurrentSearchErr = 0
	$script:stats.CurrentFilesNotFound = 0
	Get-ChildItem -LiteralPath $Paths -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +searchErrors | ForEach-Object { $newFiles[(Add-LongPrefix $_.FullName)] = $null }
	foreach ($err in $searchErrors) {
		Write-Log ('Search error: ' + $err.Exception.Message) -ForegroundColor Red
		$script:stats.CurrentSearchErr++
	}
	$script:stats.SearchErr += $script:stats.CurrentSearchErr
	if ($newFiles.Count -gt 0) {
		Write-Log ('Files found: ' + $newFiles.Count)
	} else {
		Write-Log 'Files not found!'
		$script:stats.CurrentFilesNotFound++
	}
	$script:stats.FilesNotFound += $script:stats.CurrentFilesNotFound
	return $newFiles
}

function Get-TimeUnit {
	param(
		[TimeUnit]$Unit
	)
	switch ($Unit) {
		([TimeUnit]::Minutes) { return 'minutes' }
		([TimeUnit]::Hours) { return 'hours' }
		([TimeUnit]::Days) { return 'days' }
		([TimeUnit]::Months) { return 'months' }
		([TimeUnit]::Years) { return 'years' }
	}
}

function Test-FileTime {
	param(
		[string]$Path,
		[TimeUnit]$Unit,
		[int]$Value
	)
	if ($Value -le 0) { throw }
	switch ($Unit) {
		([TimeUnit]::Minutes) {
			$time = $script:now.AddMinutes(-$Value)
			break
		}
		([TimeUnit]::Hours) {
			$time = $script:now.AddHours(-$Value)
			break
		}
		([TimeUnit]::Days) {
			$time = $script:now.AddDays(-$Value)
			break
		}
		([TimeUnit]::Months) {
			$time = $script:now.AddMonths(-$Value)
			break
		}
		([TimeUnit]::Years) {
			$time = $script:now.AddYears(-$Value)
			break
		}
		default { throw }
	}
	return ([System.IO.File]::GetLastWriteTime($Path) -ge $time) -or ([System.IO.File]::GetCreationTime($Path) -ge $time)
}

function Test-FileMask {
	param(
		[string]$Path,
		[string[]]$Masks,
		[bool]$Include
	)
	$match = $false
	foreach ($mask in $Masks) {
		if ($mask.Contains('\')) {
			$match = (Remove-LongPrefix $Path) -like $mask
		} else {
			$match = [System.IO.Path]::GetFileName($Path) -like $mask
		}
		if ($match) { break }
	}
	return $match -eq $Include
}

function Test-FilePath {
	param(
		[string]$File,
		[string[]]$Paths
	)
	foreach ($path in $Paths) {
		if (($File -ieq $path) -or $File.StartsWith($path.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
	}
	return $false
}

function Write-Log {
	param(
		[string]$Text,
		[ConsoleColor]$ForegroundColor,
		[switch]$NoHost
	)
	if (-not $NoHost) {
		if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
			Write-Host $Text -ForegroundColor $ForegroundColor
		} else {
			Write-Host $Text
		}
	}
	if ([string]::IsNullOrEmpty($Text)) {
		$script:logList.Add('')
	} else {
		$script:logList.Add('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Text)
	}
}

function Start-Clear {
	if (-not $script:options.Quiet) { Clear-Host }
}

function Start-Pause {
	if (-not $script:options.Quiet) {
		Write-Host ''
		pause
	}
}

if (-not ([System.Management.Automation.PSTypeName]"NTDLL.Win32Crc32").Type) {
	Add-Type -TypeDefinition 'namespace NTDLL {
		public class Win32Crc32 {
			[System.Runtime.InteropServices.DllImport("ntdll.dll", CallingConvention = System.Runtime.InteropServices.CallingConvention.StdCall)]
			public static extern uint RtlComputeCrc32(uint dwInitial, byte[] pData, int iLen);
		}
	}'
}
Parse-Arguments $env:BATARGS
$script:auto = $script:checkPaths.Count -eq 0
$batFile = Get-LongPath $env:BATFILE
$batDir = Get-LongPath $env:BATDIR
if (($script:checkFiles.Count -eq 0) -and (-not $script:options.NoAuto)) {
	$script:checkFiles = @(Get-ChildItem -LiteralPath $batDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $script:fileAlgorithms.ContainsKey($_.Extension) })
}
if ($script:auto -and $script:options.NoAuto) {
	$script:options.MissingEntries = $false
	if ($script:options.VerifyHash -eq [VerifyMode]::Paths) { $script:options.VerifyHash = [VerifyMode]::No }
}
if ($script:options.ShowMenu) { Show-MainMenu }
if ($script:checkFiles.Count -eq 0) {
	Start-Clear
	Write-Host 'Checksum files not found!' -ForegroundColor Red
	Write-Host 'Supported file formats: .sfv, .md5, .sha1, .sha256, .sha384, .sha512' -ForegroundColor Red
	Start-Pause
	exit 1000
}
$regexOptions = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$regexPatterns = @{
	'.sfv' = [regex]::new('^(.*?)\s+([a-f0-9]{8})$', $regexOptions)
	'.md5' = [regex]::new('^([a-f0-9]{32})\s+\*?(.*)$', $regexOptions)
	'.sha1' = [regex]::new('^([a-f0-9]{40})\s+\*?(.*)$', $regexOptions)
	'.sha256' = [regex]::new('^([a-f0-9]{64})\s+\*?(.*)$', $regexOptions)
	'.sha384' = [regex]::new('^([a-f0-9]{96})\s+\*?(.*)$', $regexOptions)
	'.sha512' = [regex]::new('^([a-f0-9]{128})\s+\*?(.*)$', $regexOptions)
}
$hashMasks = @()
if (-not [string]::IsNullOrEmpty($script:options.HashMask)) {
	$hashMasks = @($script:options.HashMask -split '\|' | Where-Object { $_ -ne '' })
}
$entMasks = @()
if (-not [string]::IsNullOrEmpty($script:options.EntMask)) {
	$entMasks = @($script:options.EntMask -split '\|' | Where-Object { $_ -ne '' })
}
$hashes = @{}
$updateObjects = [ordered]@{}
$newFiles = [ordered]@{}
$script:now = Get-Date
Write-Log 'Check started' -NoHost
Write-Log '' -NoHost
Start-Clear
if (($script:options.MissingEntries -or ($script:options.VerifyHash -eq [VerifyMode]::Paths)) -and (-not $script:auto)) {
	if ($script:checkPaths.Count -eq 1) {
		Write-Log ('Search path: ' + (Remove-LongPrefix $script:checkPaths[0]))
	} else {
		Write-Log 'Search paths:'
		foreach ($path in $script:checkPaths) {
			Write-Log (Remove-LongPrefix $path)
		}
	}
	if ($script:options.MissingEntries) { $newFiles = Get-NewFiles $script:checkPaths }
	Write-Log ''
}
foreach ($file in $script:checkFiles) {
	$fileName = Add-LongPrefix $file.FullName
	$fileDir = Add-LongPrefix $file.DirectoryName
	$fileExtension = $file.Extension
	$fileStats = [PSCustomObject]@{
		EntriesChecked = 0
		LinesSkipped = 0
		DuplicateEntries = 0
		MissingEntries = 0
		MissingFiles = 0
		HashesCalculated = 0
		HashesNotCalculated = 0
		HashMismatches = 0
	}
	Write-Log ('Checking checksum file: ' + (Remove-LongPrefix $fileName))
	if (($script:options.MissingEntries -or ($script:options.VerifyHash -eq [VerifyMode]::Paths)) -and $script:auto) {
		$newFiles = [ordered]@{}
		$fileBaseNameDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
		if ([System.IO.Directory]::Exists($fileBaseNameDir)) {
			$script:checkPaths = $fileBaseNameDir
		} else {
			$script:checkPaths = $fileDir
		}
		Write-Log ('Search path: ' + (Remove-LongPrefix $script:checkPaths))
		if ($script:options.MissingEntries) { $newFiles = Get-NewFiles $script:checkPaths }
	}
	$encoding = Get-Encoding $fileName
	$algorithm = $script:fileAlgorithms[$fileExtension]
	$pattern = $regexPatterns[$fileExtension]
	$entries = [ordered]@{}
	$keys = @{}
	try {
		foreach ($line in [System.IO.File]::ReadLines($fileName, $encoding)) {
			$ent = $null
			$entPath = $null
			$entHash = $null
			$match = $pattern.Match($line)
			if ($match.Success) {
				if ($algorithm -ieq 'CRC32') {
					$ent = $match.Groups[1].Value
					$entHash = $match.Groups[2].Value
				} else {
					$entHash = $match.Groups[1].Value
					$ent = $match.Groups[2].Value
				}
			}
			if (-not [string]::IsNullOrEmpty($ent)) {
				try {
					if ([System.IO.Path]::IsPathRooted($ent)) {
						$entPath = Get-LongPath $ent
					} else {
						$entPath = Get-LongPath ([System.IO.Path]::Combine($fileDir, $ent))
					}
					if (($algorithm -ieq 'CRC32') -and $line.TrimStart().StartsWith(';', [System.StringComparison]::Ordinal) -and (-not [System.IO.File]::Exists($entPath))) {
						$ent = $null
					}
				} catch {
					$ent = $null
				}
			}
			if (-not [string]::IsNullOrEmpty($ent)) {
				$fileStats.EntriesChecked++
				$entKey = $entPath
				if ($keys.ContainsKey($entKey)) {
					$fileStats.DuplicateEntries++
					if ($script:options.DuplicateEntries) {
						Write-Log ('Duplicate entry: ' + $ent) -ForegroundColor Cyan
						continue
					} else {
						$entKey = '<DUP' + $fileStats.DuplicateEntries + '>'
					}
				} else {
					$keys[$entKey] = $null
				}
				if ([System.IO.File]::Exists($entPath)) {
					$entLine = $line
					if ($script:options.VerifyHash -ne [VerifyMode]::No) {
						$verifyHash = $true
						if (($script:options.VerifyHash -eq [VerifyMode]::Paths) -and (-not (Test-FilePath $entPath $script:checkPaths))) { $verifyHash = $false }
						if (($hashMasks.Count -gt 0) -and (-not (Test-FileMask $entPath $hashMasks $script:options.HashMaskInclude))) { $verifyHash = $false }
						if (($script:options.HashTimeValue -gt 0) -and (-not (Test-FileTime $entPath $script:options.HashTimeUnit $script:options.HashTimeValue))) { $verifyHash = $false }
						if ($verifyHash) {
							$hashKey = '<' + $algorithm + '>' + $entPath
							if ($hashes.ContainsKey($hashKey)) {
								$hash = $hashes[$hashKey]
							} else {
								$hash = Get-HashValue $entPath $algorithm
								if (-not [string]::IsNullOrEmpty($hash)) { $hashes[$hashKey] = $hash }
							}
							if (-not [string]::IsNullOrEmpty($hash)) {
								if ($entHash -ine $hash) {
									Write-Log ('Hash mismatch: ' + $ent) -ForegroundColor Red
									$fileStats.HashMismatches++
									$entLine = Get-EntLine $ent $hash $algorithm
								} elseif ($script:options.HashVerbose) {
									Write-Log ('Hash matched: ' + $ent) -ForegroundColor Green
								}
								$fileStats.HashesCalculated++
							} else {
								Write-Log ('Failed to calculate hash: ' + $ent) -ForegroundColor Red
								$fileStats.HashesNotCalculated++
							}
						}
					}
					$entries[$entKey] = $entLine
				} else {
					if ($script:options.MissingFiles -or ($script:options.VerifyHash -eq [VerifyMode]::All) -or (($script:options.VerifyHash -eq [VerifyMode]::Paths) -and (Test-FilePath $entPath $script:checkPaths))) {
						Write-Log ('Missing file: ' + $ent) -ForegroundColor Magenta
						$fileStats.MissingFiles++
					}
					if (-not $script:options.MissingFiles) { $entries[$entKey] = $line }
				}
			} else {
				$fileStats.LinesSkipped++
				$entries['<SKIP' + $fileStats.LinesSkipped + '>'] = $line
			}
		}
	} catch {
		Write-Log 'Failed to check checksum file!' -ForegroundColor Red
		Write-Log ''
		$script:stats.FilesNotChecked++
		continue
	}
	$newEntries = [ordered]@{}
	if ($script:options.MissingEntries) {
		foreach ($entPath in $newFiles.Keys) {
			if ($entries.Contains($entPath)) { continue }
			if (($entPath -ieq $fileName) -or ($entPath -ieq $batFile)) { continue }
			$baseDir = $fileDir.TrimEnd('\') + '\'
			if ((-not $script:options.AbsPaths) -and $entPath.StartsWith($baseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
				$ent = $entPath.Substring($baseDir.Length).TrimStart('\')
			} else {
				$ent = Remove-LongPrefix $entPath
			}
			if (($entMasks.Count -gt 0) -and (-not (Test-FileMask $entPath $entMasks $script:options.EntMaskInclude))) { continue }
			if (($script:options.EntTimeValue -gt 0) -and (-not (Test-FileTime $entPath $script:options.EntTimeUnit $script:options.EntTimeValue))) { continue }
			Write-Log ('Missing entry: ' + $ent) -ForegroundColor Yellow
			$fileStats.MissingEntries++
			$newEntries[$entPath] = $ent
		}
	}
	$checkWarnings = $false
	$checkErrors = $false
	$systemErrors = $false
	$entriesDeleted = 0
	if ($fileStats.EntriesChecked) {
		Write-Log ('Checked entries in checksum file: ' + $fileStats.EntriesChecked)
		$script:stats.EntriesChecked += $fileStats.EntriesChecked
	} else {
		Write-Log 'Entries not found in checksum file!' -ForegroundColor Yellow
		$script:stats.EntriesNotFound++
		$checkWarnings = $true
	}
	if ($script:auto) {
		if ($script:stats.CurrentSearchErr) {
			Write-Log ('Search errors: ' + $script:stats.CurrentSearchErr) -ForegroundColor Red
			$systemErrors = $true
		}
		if ($script:stats.CurrentFilesNotFound) {
			Write-Log 'Files not found in search paths!' -ForegroundColor Yellow
			$checkWarnings = $true
		}
	} else {
		if ($script:stats.SearchErr) {
			if ($script:checkFiles.Count -eq 1) { Write-Log ('Search errors: ' + $script:stats.SearchErr) -ForegroundColor Red }
			$systemErrors = $true
		}
		if ($script:stats.FilesNotFound) {
			if ($script:checkFiles.Count -eq 1) { Write-Log 'Files not found in search paths!' -ForegroundColor Yellow }
			$checkWarnings = $true
		}
	}
	if ($fileStats.LinesSkipped) {
		Write-Log ('Lines skipped: ' + $fileStats.LinesSkipped)
		$script:stats.LinesSkipped += $fileStats.LinesSkipped
	}
	if ($script:options.DuplicateEntries -and $fileStats.DuplicateEntries) {
		Write-Log ('Duplicate entries: ' + $fileStats.DuplicateEntries) -ForegroundColor Cyan
		$script:stats.DuplicateEntries += $fileStats.DuplicateEntries
		$entriesDeleted += $fileStats.DuplicateEntries
		$checkErrors = $true
	}
	if ($fileStats.MissingFiles) {
		Write-Log ('Missing files: ' + $fileStats.MissingFiles) -ForegroundColor Magenta
		$script:stats.MissingFiles += $fileStats.MissingFiles
		if ($script:options.MissingFiles) {
			$entriesDeleted += $fileStats.MissingFiles
			$checkErrors = $true
		} else {
			$checkWarnings = $true
		}
	}
	if ($fileStats.MissingEntries) {
		Write-Log ('Missing entries: ' + $fileStats.MissingEntries) -ForegroundColor Yellow
		$script:stats.MissingEntries += $fileStats.MissingEntries
		$checkErrors = $true
	}
	if ($fileStats.HashesCalculated) {
		Write-Log ('Hashes calculated: ' + $fileStats.HashesCalculated)
		$script:stats.HashesCalculated += $fileStats.HashesCalculated
	}
	if ($fileStats.HashesNotCalculated) {
		Write-Log ('Hashes not calculated: ' + $fileStats.HashesNotCalculated) -ForegroundColor Red
		$script:stats.HashesNotCalculated += $fileStats.HashesNotCalculated
		$systemErrors = $true
	}
	if ($fileStats.HashMismatches) {
		Write-Log ('Hash mismatches: ' + $fileStats.HashMismatches) -ForegroundColor Red
		$script:stats.HashMismatches += $fileStats.HashMismatches
		$checkErrors = $true
	}
	if ($checkErrors -and (-not ($systemErrors -and $script:options.SafeUpdate))) {
		$updateObjects[$fileName] = [PSCustomObject]@{
			Algorithm = $algorithm
			Encoding = $encoding
			Entries = $entries
			NewEntries = $newEntries
			EntriesDeleted = $entriesDeleted
			EntriesUpdated = $fileStats.HashMismatches
			HashesAdded = 0
			HashesNotAdded = 0
		}
	}
	if ($systemErrors) {
		Write-Log 'Checksum file checked with errors!' -ForegroundColor Red
		$script:stats.FilesCheckedErr++
	} else {
		if (-not ($checkErrors -or $checkWarnings)) {
			Write-Log 'Checksum file checked successfully!' -ForegroundColor Green
		}
		$script:stats.FilesChecked++
	}
	Write-Log ''
}
Write-Log 'Check completed!'
if ($script:checkFiles.Count -ne 1) {
	Write-Log ''
	$checkWarnings = $false
	$checkErrors = $false
	$systemErrors = $false
	if ($script:stats.FilesChecked) { Write-Log ('Checksum files checked: ' + $script:stats.FilesChecked) }
	if ($script:stats.FilesCheckedErr) {
		Write-Log ('Checksum files checked with errors: ' + $script:stats.FilesCheckedErr) -ForegroundColor Red
		$systemErrors = $true
	}
	if ($script:stats.FilesNotChecked) {
		Write-Log ('Not checked checksum files: ' + $script:stats.FilesNotChecked) -ForegroundColor Red
		$systemErrors = $true
	}
	if ($script:stats.FilesChecked -or $script:stats.FilesCheckedErr) {
		if ($script:stats.EntriesChecked) {
			Write-Log ('Checked entries in checksum files: ' + $script:stats.EntriesChecked)
			if ($script:stats.EntriesNotFound) {
				Write-Log ('Entries not found in checksum file: ' + $script:stats.EntriesNotFound) -ForegroundColor Yellow
				$checkWarnings = $true
			}
		} else {
			Write-Log 'Entries not found in checksum files!' -ForegroundColor Yellow
			$checkWarnings = $true
		}
		if ($script:stats.SearchErr) {
			Write-Log ('Search errors: ' + $script:stats.SearchErr) -ForegroundColor Red
			$systemErrors = $true
		}
		if ($script:stats.FilesNotFound) {
			if ($script:auto) {
				Write-Log ('Files not found in search paths: ' + $script:stats.FilesNotFound) -ForegroundColor Yellow
			} else {
				Write-Log 'Files not found in search paths!' -ForegroundColor Yellow
			}
			$checkWarnings = $true
		}
		if ($script:stats.LinesSkipped) { Write-Log ('Lines skipped: ' + $script:stats.LinesSkipped) }
		if ($script:options.DuplicateEntries -and $script:stats.DuplicateEntries) {
			Write-Log ('Duplicate entries: ' + $script:stats.DuplicateEntries) -ForegroundColor Cyan
			$checkErrors = $true
		}
		if ($script:stats.MissingFiles) {
			Write-Log ('Missing files: ' + $script:stats.MissingFiles) -ForegroundColor Magenta
			if ($script:options.MissingFiles) { $checkErrors = $true } else { $checkWarnings = $true }
		}
		if ($script:stats.MissingEntries) {
			Write-Log ('Missing entries: ' + $script:stats.MissingEntries) -ForegroundColor Yellow
			$checkErrors = $true
		}
		if ($script:stats.HashesCalculated) { Write-Log ('Hashes calculated: ' + $script:stats.HashesCalculated) }
		if ($script:stats.HashesNotCalculated) {
			Write-Log ('Hashes not calculated: ' + $script:stats.HashesNotCalculated) -ForegroundColor Red
			$systemErrors = $true
		}
		if ($script:stats.HashMismatches) {
			Write-Log ('Hash mismatches: ' + $script:stats.HashMismatches) -ForegroundColor Red
			$checkErrors = $true
		}
	}
	if ($systemErrors) {
		Write-Log 'Check completed with errors!' -ForegroundColor Red
	} elseif (-not ($checkErrors -or $checkWarnings)) {
		Write-Log 'Check completed successfully!' -ForegroundColor Green
	}
}
$finalPause = $true
if ($updateObjects.Count -gt 0) {
	if ($script:options.UpdateMsg) {
		Write-Host ''
		$msg = $true
		while ($msg) {
			if ($systemErrors) {
				Write-Host 'Update' -ForegroundColor Red -NoNewline
			} else {
				Write-Host 'Update' -ForegroundColor Green -NoNewline
			}
			Write-Host ' checksum files? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$readValue = Read-Host ')'
			switch -Regex ($readValue.Trim()) {
				'^$' {
					$script:options.Update = $false
					$msg = $false
					break
				}
				'^(y|yes)$' {
					$script:options.Update = $true
					$msg = $false
					break
				}
				'^(n|no)$' {
					$script:options.Update = $false
					$msg = $false
					break
				}
			}
		}
		$finalPause = $false
	}
	if ($script:options.Update) {
		Write-Log ''
		Write-Log 'Update started' -NoHost
		Write-Log '' -NoHost
		foreach ($fileName in $updateObjects.Keys) {
			Write-Log ('Updating checksum file: ' + (Remove-LongPrefix $fileName))
			try {
				$updObj = $updateObjects[$fileName]
				if ($script:options.MissingEntries) {
					foreach ($entPath in $updObj.NewEntries.Keys) {
						$hashKey = '<' + $updObj.Algorithm + '>' + $entPath
						if ($hashes.ContainsKey($hashKey)) {
							$hash = $hashes[$hashKey]
						} else {
							$hash = Get-HashValue $entPath $updObj.Algorithm
							if (-not [string]::IsNullOrEmpty($hash)) { $hashes[$hashKey] = $hash }
						}
						if (-not [string]::IsNullOrEmpty($hash)) {
							$updObj.Entries[$entPath] = Get-EntLine $updObj.NewEntries[$entPath] $hash $updObj.Algorithm
							if ($script:options.HashVerbose) { Write-Log ('Hash calculated: ' + $updObj.NewEntries[$entPath]) -ForegroundColor Green }
							$updObj.HashesAdded++
						} else {
							Write-Log ('Failed to calculate hash: ' + $updObj.NewEntries[$entPath]) -ForegroundColor Red
							if ($script:options.SafeUpdate) { throw }
							$updObj.HashesNotAdded++
						}
					}
				}
				if ($updObj.Encoding.CodePage -eq $script:ansi.CodePage) {
					try {
						foreach ($line in $updObj.Entries.Values) {
							[void]$updObj.Encoding.GetBytes($line)
						}
					} catch [System.Text.EncoderFallbackException] {
						$updObj.Encoding = $script:utf
					}
				}
				$tempFile = $fileName + '_' + [System.Guid]::NewGuid().ToString('N') + '.tmp'
				$bakIdx = 0
				$bakFile = $fileName + '.bak'
				$bakExist = $false
				[System.IO.File]::WriteAllLines($tempFile, $updObj.Entries.Values, $updObj.Encoding)
				while ($true) {
					try {
						[System.IO.File]::Move($fileName, $bakFile)
						$bakExist = $true
						break
					} catch [System.IO.IOException] {
						if (($_.Exception.HResult -band 0xFFFF) -in 0x50, 0xB7) {
							$bakIdx++
							$bakFile = $fileName + '.bak' + $bakIdx
						} else {
							throw
						}
					}
				}
				Write-Log ('Backup created: ' + (Remove-LongPrefix $bakFile))
				[System.IO.File]::Move($tempFile, $fileName)
			} catch {
				Write-Log 'Failed to update checksum file!' -ForegroundColor Red
				$script:stats.FilesNotUpdated++
				if ($bakExist -and (-not [System.IO.File]::Exists($fileName)) -and [System.IO.File]::Exists($bakFile)) {
					try {
						[System.IO.File]::Move($bakFile, $fileName)
						Write-Log 'File restored from backup!' -ForegroundColor Red
					} catch {
						Write-Log 'File not restored from backup!' -ForegroundColor Red
					}
				}
				Write-Log ''
				continue
			} finally {
				if ([System.IO.File]::Exists($tempFile)) {
					try { [System.IO.File]::Delete($tempFile) } catch {}
				}
			}
			$systemErrors = $false
			if ($updObj.EntriesDeleted) {
				Write-Log ('Entries deleted: ' + $updObj.EntriesDeleted)
				$script:stats.EntriesDeleted += $updObj.EntriesDeleted
			}
			if ($updObj.EntriesUpdated) {
				Write-Log ('Entries updated: ' + $updObj.EntriesUpdated)
				$script:stats.EntriesUpdated += $updObj.EntriesUpdated
			}
			if ($updObj.HashesAdded) {
				Write-Log ('Entries added: ' + $updObj.HashesAdded)
				$script:stats.HashesAdded += $updObj.HashesAdded
			}
			if ($updObj.HashesNotAdded) {
				Write-Log ('Entries not added: ' + $updObj.HashesNotAdded) -ForegroundColor Red
				$script:stats.HashesNotAdded += $updObj.HashesNotAdded
				$systemErrors = $true
			}
			if ($systemErrors) {
				Write-Log 'Checksum file updated with errors!' -ForegroundColor Red
				$script:stats.FilesUpdatedErr++
			} else {
				Write-Log 'Checksum file updated successfully!' -ForegroundColor Green
				$script:stats.FilesUpdated++
			}
			Write-Log ''
		}
		Write-Log 'Update completed!'
		if ($updateObjects.Count -ne 1) {
			Write-Log ''
			$systemErrors = $false
			if ($script:stats.FilesUpdated) { Write-Log ('Checksum files updated: ' + $script:stats.FilesUpdated) }
			if ($script:stats.FilesUpdatedErr) {
				Write-Log ('Checksum files updated with errors: ' + $script:stats.FilesUpdatedErr) -ForegroundColor Red
				$systemErrors = $true
			}
			if ($script:stats.FilesNotUpdated) {
				Write-Log ('Checksum files not updated: ' + $script:stats.FilesNotUpdated) -ForegroundColor Red
				$systemErrors = $true
			}
			if ($script:stats.EntriesDeleted) { Write-Log ('Entries deleted: ' + $script:stats.EntriesDeleted) }
			if ($script:stats.EntriesUpdated) { Write-Log ('Entries updated: ' + $script:stats.EntriesUpdated) }
			if ($script:stats.HashesAdded) { Write-Log ('Entries added: ' + $script:stats.HashesAdded) }
			if ($script:stats.HashesNotAdded) {
				Write-Log ('Entries not added: ' + $script:stats.HashesNotAdded) -ForegroundColor Red
				$systemErrors = $true
			}
			if ($systemErrors) {
				Write-Log 'Update completed with errors!' -ForegroundColor Red
			} else {
				Write-Log 'Update completed successfully!' -ForegroundColor Green
			}
		}
		$finalPause = $true
	}
}
if ($script:options.LogMsg) {
	Write-Host ''
	$msg = $true
	while ($msg) {
		Write-Host 'Save check log? (Yes / ' -NoNewline
		Write-Host '[No]' -ForegroundColor Green -NoNewline
		$readValue = Read-Host ')'
		switch -Regex ($readValue.Trim()) {
			'^$' {
				$script:options.Log = $false
				$msg = $false
				break
			}
			'^(y|yes)$' {
				$script:options.Log = $true
				$msg = $false
				break
			}
			'^(n|no)$' {
				$script:options.Log = $false
				$msg = $false
				break
			}
		}
	}
	$finalPause = $false
}
if ($script:options.Log) {
	Write-Host ''
	$encoding = $script:utf
	$logName = 'ChecksumListChecker_' + $script:now.ToString('yyyy-MM-dd_HH-mm-ss')
	$tempFile = [System.IO.Path]::Combine($batDir, ($logName + '_' + [System.Guid]::NewGuid().ToString('N') + '.tmp'))
	$logIdx = 0
	$logFile = [System.IO.Path]::Combine($batDir, $logName + '.txt')
	try {
		[System.IO.File]::WriteAllLines($tempFile, $script:logList, $encoding)
		while ($true) {
			try {
				[System.IO.File]::Move($tempFile, $logFile)
				break
			} catch [System.IO.IOException] {
				if (($_.Exception.HResult -band 0xFFFF) -in 0x50, 0xB7) {
					$logIdx++
					$logFile = [System.IO.Path]::Combine($batDir, $logName + ' (' + $logIdx + ').txt')
				} else {
					throw
				}
			}
		}
		Write-Host ('Check log saved to file: ' + (Remove-LongPrefix $logFile))
	} catch {
		Write-Host 'Failed to save check log!' -ForegroundColor Red
	} finally {
		if ([System.IO.File]::Exists($tempFile)) {
			try { [System.IO.File]::Delete($tempFile) } catch {}
		}
	}
	$finalPause = $true
}
if ($finalPause) { Start-Pause }

$exitCode = 0
if ($script:stats.FilesNotChecked) { $exitCode += 1 }
if ($script:stats.FilesNotUpdated) { $exitCode += 2 }
if ($script:stats.HashesNotCalculated) { $exitCode += 4 }
if ($script:stats.HashesNotAdded) { $exitCode += 8 }
if ($script:stats.SearchErr) { $exitCode += 16 }
if (($script:options.DuplicateEntries -and $script:stats.DuplicateEntries) -or ($script:options.MissingFiles -and $script:stats.MissingFiles) -or $script:stats.MissingEntries -or $script:stats.HashMismatches) { $exitCode += 32 }
if ($script:stats.EntriesNotFound) { $exitCode += 64 }
if ($script:stats.FilesNotFound) { $exitCode += 128 }
if ($exitCode -gt 0) { $exitCode += 1000 }
exit $exitCode
