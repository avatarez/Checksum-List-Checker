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

if (-not ([System.Management.Automation.PSTypeName]"NTDLL.Win32Crc32").Type) {
	Add-Type -TypeDefinition 'namespace NTDLL {
		public class Win32Crc32 {
			[System.Runtime.InteropServices.DllImport("ntdll.dll", CallingConvention = System.Runtime.InteropServices.CallingConvention.StdCall)]
			public static extern uint RtlComputeCrc32(uint dwInitial, byte[] pData, int iLen);
		}
	}'
}

enum TimeUnit {
	Minutes
	Hours
	Days
	Months
	Years
}

enum HashMode {
	No
	All
	SearchPaths
}

enum MaskMode {
	EntInclude
	EntExclude
	HashInclude
	HashExclude
}

enum TimeMode {
	EntTime
	HashTime
}

class CustomException : System.Exception {
	CustomException([string]$message) : base($message) {}
}

$script:opt = [PSCustomObject]@{
	ShowMenu = $true
	DuplicateEntries = $true
	MissingFiles = $true
	MissingEntries = $true
	VerifyHashes = [HashMode]::No
	EntInclude = $null
	EntExclude = $null
	EntTimeUnit = $null
	EntTime = 0
	HashInclude = $null
	HashExclude = $null
	HashTimeUnit = $null
	HashTime = 0
	Verbose = $true
	AbsolutePaths = $false
	SysResolution = $true
	Update = $false
	UpdateMsg = $true
	Log = $false
	LogMsg = $true
	Safe = $false
	NoAuto = $false
	Quiet = $false
}

$script:stat = [PSCustomObject]@{
	SysErr = 0
	GlobalErr = 0
	CheckErr = 0
	UpdateErr = 0
	FilesChecked = 0
	FilesCheckedErr = 0
	FilesNotChecked = 0
	FilesUpdated = 0
	FilesUpdatedErr = 0
	FilesNotUpdated = 0
	FilesEmpty = 0
	SearchEmpty = 0
	EntChecked = 0
	Skipped = 0
	DuplicateEntries = 0
	MissingEntries = 0
	MissingFiles = 0
	HashCalc = 0
	HashNotCalc = 0
	HashMismatch = 0
	EntDeleted = 0
	EntUpdated = 0
	EntAdded = 0
	EntNotAdded = 0
}

$script:algorithms = @{
	'.sfv' = 'CRC32'
	'.md5' = 'MD5'
	'.sha1' = 'SHA1'
	'.sha256' = 'SHA256'
	'.sha384' = 'SHA384'
	'.sha512' = 'SHA512'
}

$script:files = @()
$script:paths = @()
$script:auto = $true
$script:log = [System.Collections.Generic.List[string]]::new()
$script:ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage, [System.Text.EncoderExceptionFallback]::new(), [System.Text.DecoderExceptionFallback]::new())
$script:utf = [System.Text.UTF8Encoding]::new($false, $true)
$script:regexDupSep = [regex]::new('\\{2,}', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Show-Menu {
	$restart = $true
	while ($restart) {
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:files.Count -eq 0) {
			Write-Host 'Checksum files: None' -ForegroundColor Red
		} elseif ($script:files.Count -eq 1) {
			Write-Host ('Checksum file: ' + (Remove-LongPrefix $script:files[0].FullName))
		} else {
			Write-Host ('Checksum files: ' + $script:files.Count)
		}
		if ($script:auto) {
			if ($script:opt.NoAuto) {
				Write-Host 'Search paths: None'
			} else {
				Write-Host 'Search paths: Auto'
			}
		} elseif ($script:paths.Count -eq 1) {
			Write-Host ('Search path: ' + (Remove-LongPrefix $script:paths[0]))
		} else {
			Write-Host ('Search paths: ' + $script:paths.Count)
		}
		Write-Host ''
		if ($script:files.Count -gt 0) {
			Write-Host '1.  [Start check]' -ForegroundColor Green
		} else {
			Write-Host '1.  [Start check]' -ForegroundColor DarkGreen
		}
		Write-Host ''
		if ($script:opt.DuplicateEntries) {
			Write-Host '2.  Check for ' -NoNewline
			Write-Host 'duplicate entries' -ForegroundColor Cyan -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '2.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'duplicate entries' -ForegroundColor DarkCyan -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:opt.MissingFiles) {
			Write-Host '3.  Check for ' -NoNewline
			Write-Host 'missing files' -ForegroundColor Magenta -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '3.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing files' -ForegroundColor DarkMagenta -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:auto -and $script:opt.NoAuto) {
			Write-Host '4.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing entries' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Not available' -ForegroundColor DarkGray
		} elseif ($script:opt.MissingEntries) {
			Write-Host '4.  Check for ' -NoNewline
			Write-Host 'missing entries' -ForegroundColor Yellow -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '4.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing entries' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:opt.VerifyHashes -eq [HashMode]::All) {
			Write-Host '5.  Verify ' -NoNewline
			Write-Host 'hashes' -ForegroundColor Red -NoNewline
			Write-Host ' (slow): All'
		} elseif ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) {
			Write-Host '5.  Verify ' -NoNewline
			Write-Host 'hashes' -ForegroundColor Red -NoNewline
			Write-Host ' (slow): By search paths'
		} else {
			Write-Host '5.  Verify ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'hashes' -ForegroundColor DarkRed -NoNewline
			Write-Host ' (slow): No' -ForegroundColor DarkGray
		}
		Write-Host ''
		Write-Host '6.  Filter options'
		Write-Host ''
		if ($script:opt.MissingEntries -or ($script:opt.VerifyHashes -ne [HashMode]::No)) {
			if ($script:opt.Verbose) {
				Write-Host '7.  Verbose ' -NoNewline
				Write-Host 'hash' -ForegroundColor Green -NoNewline
				Write-Host ' mode: Yes'
			} else {
				Write-Host '7.  Verbose ' -ForegroundColor DarkGray -NoNewline
				Write-Host 'hash' -ForegroundColor DarkGreen -NoNewline
				Write-Host ' mode: No' -ForegroundColor DarkGray
			}
		} else {
			Write-Host '7.  Verbose ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'hash' -ForegroundColor DarkGreen -NoNewline
			Write-Host ' mode: Not available' -ForegroundColor DarkGray
		}
		if ($script:opt.MissingEntries) {
			if ($script:opt.AbsolutePaths) {
				Write-Host '8.  Missing entries path mode: Absolute'
			} else {
				Write-Host '8.  Missing entries path mode: Relative'
			}
		} else {
			Write-Host '8.  Missing entries path mode: Not available' -ForegroundColor DarkGray
		}
		if ($script:opt.SysResolution) {
			Write-Host '9.  Path resolution mode: System'
		} else {
			Write-Host '9.  Path resolution mode: Internal'
		}
		Write-Host ''
		Write-Host '10. View checksum files and search paths'
		Write-Host ''
		Write-Host '0.  Exit'
		Write-Host ''
		$read = Read-Host 'Select option (0-10)'
		switch ($read.Trim()) {
			'' {
				$restart = $script:files.Count -eq 0
				break
			}
			'1' {
				$restart = $script:files.Count -eq 0
				break
			}
			'2' {
				$script:opt.DuplicateEntries = -not $script:opt.DuplicateEntries
				break
			}
			'3' {
				$script:opt.MissingFiles = -not $script:opt.MissingFiles
				break
			}
			'4' {
				if (-not ($script:auto -and $script:opt.NoAuto)) { $script:opt.MissingEntries = -not $script:opt.MissingEntries }
				break
			}
			'5' {
				if ($script:opt.VerifyHashes -eq [HashMode]::No) {
					$script:opt.VerifyHashes = [HashMode]::All
				} elseif ($script:opt.VerifyHashes -eq [HashMode]::All) {
					if ($script:auto -and $script:opt.NoAuto) {
						$script:opt.VerifyHashes = [HashMode]::No
					} else {
						$script:opt.VerifyHashes = [HashMode]::SearchPaths
					}
				} else {
					$script:opt.VerifyHashes = [HashMode]::No
				}
				break
			}
			'6' {
				Show-Filters
				break
			}
			'7' {
				if ($script:opt.MissingEntries -or ($script:opt.VerifyHashes -ne [HashMode]::No)) { $script:opt.Verbose = -not $script:opt.Verbose }
				break
			}
			'8' {
				if ($script:opt.MissingEntries) { $script:opt.AbsolutePaths = -not $script:opt.AbsolutePaths }
				break
			}
			'9' {
				$script:opt.SysResolution = -not $script:opt.SysResolution
				break
			}
			'10' {
				Show-Paths
				break
			}
			'0' {
				exit 0
			}
		}
	}
}

function Show-Filters {
	$restart = $true
	while ($restart) {
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:opt.MissingEntries) {
			Write-Host 'Missing entries check filter' -ForegroundColor Yellow
			Write-Host ''
			if ($script:opt.EntInclude) {
				Write-Host ('1. Include file mask: ' + $script:opt.EntInclude)
			} else {
				Write-Host '1. Include file mask: No' -ForegroundColor DarkGray
			}
			if ($script:opt.EntExclude) {
				Write-Host ('2. Exclude file mask: ' + $script:opt.EntExclude)
			} else {
				Write-Host '2. Exclude file mask: No' -ForegroundColor DarkGray
			}
			if ($script:opt.EntTime -gt 0) {
				Write-Host ('3. File modification time (' + (Get-TimeUnit $script:opt.EntTimeUnit) + '): ' + $script:opt.EntTime)
			} else {
				Write-Host '3. File modification time: No' -ForegroundColor DarkGray
			}
		} else {
			Write-Host 'Missing entries check filter' -ForegroundColor DarkYellow
			Write-Host ''
			Write-Host '1. Include file mask: Not available' -ForegroundColor DarkGray
			Write-Host '2. Exclude file mask: Not available' -ForegroundColor DarkGray
			Write-Host '3. File modification time: Not available' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:opt.VerifyHashes -ne [HashMode]::No) {
			Write-Host 'Hash verification filter' -ForegroundColor Red
			Write-Host ''
			if ($script:opt.HashInclude) {
				Write-Host ('4. Include file mask: ' + $script:opt.HashInclude)
			} else {
				Write-Host '4. Include file mask: No' -ForegroundColor DarkGray
			}
			if ($script:opt.HashExclude) {
				Write-Host ('5. Exclude file mask: ' + $script:opt.HashExclude)
			} else {
				Write-Host '5. Exclude file mask: No' -ForegroundColor DarkGray
			}
			if ($script:opt.HashTime -gt 0) {
				Write-Host ('6. File modification time (' + (Get-TimeUnit $script:opt.HashTimeUnit) + '): ' + $script:opt.HashTime)
			} else {
				Write-Host '6. File modification time: No' -ForegroundColor DarkGray
			}
		} else {
			Write-Host 'Hash verification filter' -ForegroundColor DarkRed
			Write-Host ''
			Write-Host '4. Include file mask: Not available' -ForegroundColor DarkGray
			Write-Host '5. Exclude file mask: Not available' -ForegroundColor DarkGray
			Write-Host '6. File modification time: Not available' -ForegroundColor DarkGray
		}
		Write-Host ''
		Write-Host '0. [Back to menu]' -ForegroundColor Green
		Write-Host ''
		$read = Read-Host 'Select option (0-6)'
		switch ($read.Trim()) {
			'' {
				$restart = $false
				break
			}
			'1' {
				if ($script:opt.MissingEntries) { Show-NewMask ([MaskMode]::EntInclude) }
				break
			}
			'2' {
				if ($script:opt.MissingEntries) { Show-NewMask ([MaskMode]::EntExclude) }
				break
			}
			'3' {
				if ($script:opt.MissingEntries) { Show-NewTime ([TimeMode]::EntTime) }
				break
			}
			'4' {
				if ($script:opt.VerifyHashes -ne [HashMode]::No) { Show-NewMask ([MaskMode]::HashInclude) }
				break
			}
			'5' {
				if ($script:opt.VerifyHashes -ne [HashMode]::No) { Show-NewMask ([MaskMode]::HashExclude) }
				break
			}
			'6' {
				if ($script:opt.VerifyHashes -ne [HashMode]::No) { Show-NewTime ([TimeMode]::HashTime) }
				break
			}
			'0' {
				$restart = $false
				break
			}
		}
	}
}

function Show-NewMask {
	param(
		[MaskMode]$maskMode
	)
	try {
		Write-Host ''
		$read = Test-Mask (Read-Host 'File mask') -Skip
	} catch {
		$read = $null
	}
	switch ($maskMode) {
		([MaskMode]::EntInclude) {
			$script:opt.EntInclude = $read
			break
		}
		([MaskMode]::EntExclude) {
			$script:opt.EntExclude = $read
			break
		}
		([MaskMode]::HashInclude) {
			$script:opt.HashInclude = $read
			break
		}
		([MaskMode]::HashExclude) {
			$script:opt.HashExclude = $read
			break
		}
	}
}

function Show-NewTime {
	param(
		[TimeMode]$timeMode
	)
	$unit = $null
	$time = 0
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
		$read = Read-Host 'Select time unit (1-5)'
		switch ($read.Trim()) {
			'1' {
				$unit = [TimeUnit]::Minutes
				break
			}
			'2' {
				$unit = [TimeUnit]::Hours
				break
			}
			'3' {
				$unit = [TimeUnit]::Days
				break
			}
			'4' {
				$unit = [TimeUnit]::Months
				break
			}
			'5' {
				$unit = [TimeUnit]::Years
				break
			}
			default { throw }
		}
		Write-Host ''
		$read = Read-Host ('Time since last file modification (' + (Get-TimeUnit $unit) + ')')
		$time = [int]$read
		Test-Time $unit $time
	} catch {
		$unit = $null
		$time = 0
	}
	switch ($timeMode) {
		([TimeMode]::EntTime) {
			$script:opt.EntTimeUnit = $unit
			$script:opt.EntTime = $time
			break
		}
		([TimeMode]::HashTime) {
			$script:opt.HashTimeUnit = $unit
			$script:opt.HashTime = $time
			break
		}
	}
}

function Show-Paths {
	$restart = $true
	while ($restart) {
		$restart = $false
		Clear-Host
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:auto -and (-not $script:opt.NoAuto)) {
			if ($script:files.Count -eq 0) {
				Write-Host 'Checksum files: None' -ForegroundColor Red
				Write-Host ''
			} else {
				foreach ($file in $script:files) {
					Write-Host ('Checksum file: ' + (Remove-LongPrefix $file.FullName))
					$fileDir = $file.DirectoryName
					$baseDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
					if ([System.IO.Directory]::Exists($baseDir)) {
						Write-Host ('Search path: ' + (Remove-LongPrefix $baseDir))
					} else {
						Write-Host ('Search path: ' + (Remove-LongPrefix $fileDir))
					}
					Write-Host ''
				}
			}
		} else {
			if ($script:files.Count -eq 0) {
				Write-Host 'Checksum files: None' -ForegroundColor Red
			} elseif ($script:files.Count -eq 1) {
				Write-Host ('Checksum file: ' + (Remove-LongPrefix $script:files[0].FullName))
			} else {
				Write-Host 'Checksum files:'
				foreach ($file in $script:files) {
					Write-Host (Remove-LongPrefix $file.FullName)
				}
			}
			Write-Host ''
			if ($script:auto -and $script:opt.NoAuto) {
				Write-Host 'Search paths: None'
			} else {
				if ($script:paths.Count -eq 1) {
					Write-Host ('Search path: ' + (Remove-LongPrefix $script:paths[0]))
				} else {
					Write-Host 'Search paths:'
					foreach ($path in $script:paths) {
						Write-Host (Remove-LongPrefix $path)
					}
				}
			}
			Write-Host ''
		}
		$msg = $true
		while ($msg) {
			Write-Host 'Set new files and paths? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$msg = $false
					break
				}
				'^(y|yes)$' {
					Write-Host ''
					Show-NewPaths
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

function Show-NewPaths {
	$read = Read-Host 'Checksum files'
	if (-not [string]::IsNullOrEmpty($read)) { Parse-Args $read -Files }
	Write-Host ''
	$read = Read-Host 'Search paths'
	if ([string]::IsNullOrEmpty($read)) {
		if (-not $script:auto) {
			$msg = $true
			while ($msg) {
				Write-Host ''
				Write-Host 'Clear search paths? (Yes / ' -NoNewline
				Write-Host '[No]' -ForegroundColor Green -NoNewline
				$read = Read-Host ')'
				switch -Regex ($read.Trim()) {
					'^$' {
						$msg = $false
						break
					}
					'^(y|yes)$' {
						$script:paths = @()
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
		Parse-Args $read -Paths -ErrorPause
		$script:auto = $script:paths.Count -eq 0
	}
	if ($script:auto -and $script:opt.NoAuto) {
		$script:opt.MissingEntries = $false
		if ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) { $script:opt.VerifyHashes = [HashMode]::No }
	}
}

function Parse-Args {
	param(
		[string]$Arguments,
		[switch]$Files,
		[switch]$Paths,
		[switch]$ErrorPause
	)
	$argList = @([regex]::Matches($Arguments, '(?:[^\s"]|"[^"]*")+') | ForEach-Object { $_.Value })
	if ($argList.Count -eq 0) { return }
	$argErr = $false
	$fileArgs = [ordered]@{}
	$pathArgs = [ordered]@{}
	$sep = $Paths
	foreach ($argRaw in $argList) {
		$arg = $argRaw.Replace('"', '')
		if (-not ($sep -or $Files)) {
			$argOpt = @()
			$argVal = $null
			if ($arg -eq '--') {
				$sep = $true
				continue
			} elseif ($arg -match '^(--[^=]+=)(.*)$') {
				$argOpt = @($Matches[1])
				$argVal = $Matches[2]
			} elseif ($arg -match '^--.+$') {
				$argOpt = @($arg)
			} elseif ($arg -match '^-(.+)$') {
				$argOpt = @($Matches[1].ToCharArray() | ForEach-Object { '-' + $_ })
			}
			if ($argOpt.Count -gt 0) {
				try {
					foreach ($opt in $argOpt) {
						switch -Regex ($opt) {
							'^(-c|--check)$' {
								$script:opt.Update = $false
								$script:opt.ShowMenu = $false
								$script:opt.UpdateMsg = $false
								$script:opt.LogMsg = $false
								break
							}
							'^(-u|--update)$' {
								$script:opt.Update = $true
								$script:opt.ShowMenu = $false
								$script:opt.UpdateMsg = $false
								$script:opt.LogMsg = $false
								break
							}
							'^(-d|--skip-duplicates)$' {
								$script:opt.DuplicateEntries = $false
								break
							}
							'^(-f|--skip-missing-files)$' {
								$script:opt.MissingFiles = $false
								break
							}
							'^(-e|--skip-missing-entries)$' {
								$script:opt.MissingEntries = $false
								break
							}
							'^(-h|--verify-all-hashes)$' {
								$script:opt.VerifyHashes = [HashMode]::All
								break
							}
							'^(-p|--verify-search-paths-hashes)$' {
								$script:opt.VerifyHashes = [HashMode]::SearchPaths
								break
							}
							'^(-v|--no-verbose)$' {
								$script:opt.Verbose = $false
								break
							}
							'^(-a|--absolute-paths)$' {
								$script:opt.AbsolutePaths = $true
								break
							}
							'^(-i|--internal-resolution)$' {
								$script:opt.SysResolution = $false
								break
							}
							'^(-l|--save-log)$' {
								$script:opt.LogMsg = $false
								$script:opt.Log = $true
								break
							}
							'^(-s|--safe)$' {
								$script:opt.Safe = $true
								break
							}
							'^(-n|--no-auto)$' {
								$script:opt.NoAuto = $true
								break
							}
							'^(-q|--quiet)$' {
								$script:opt.ShowMenu = $false
								$script:opt.UpdateMsg = $false
								$script:opt.LogMsg = $false
								$script:opt.Quiet = $true
								break
							}
							'^--missing-entries-include=$' {
								$script:opt.EntInclude = Test-Mask $argVal
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-exclude=$' {
								$script:opt.EntExclude = Test-Mask $argVal
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-minutes=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Minutes) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Minutes
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-hours=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Hours) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Hours
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-days=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Days) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Days
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-months=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Months) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Months
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-years=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Years) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Years
								$script:opt.MissingEntries = $true
								break
							}
							'^--hashes-include=$' {
								$script:opt.HashInclude = Test-Mask $argVal
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-exclude=$' {
								$script:opt.HashExclude = Test-Mask $argVal
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-minutes=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Minutes) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Minutes
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-hours=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Hours) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Hours
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-days=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Days) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Days
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-months=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Months) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Months
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-years=$' {
								$intVal = [int]$argVal
								Test-Time ([TimeUnit]::Years) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Years
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							default { throw }
						}
					}
				} catch {
					Write-Host ('Invalid option: ' + $argRaw) -ForegroundColor Red
					Invoke-Pause
					exit 2
				}
				continue
			}
		}
		try {
			$argObjects = @()
			if ((Remove-LongPrefix $arg) -match '[*?]') {
				$argName = [System.IO.Path]::GetFileName($arg)
				$argDir = [System.IO.Path]::GetDirectoryName($arg)
				if (-not $argDir) { $argDir = ([System.IO.Directory]::GetCurrentDirectory()) }
				$argDir = Get-LongPath $argDir
				$argObjects = @(Get-ChildItem -LiteralPath $argDir -Filter $argName -Force -ErrorAction SilentlyContinue)
			} else {
				$argName = Get-LongPath $arg
				$argObjects = @(Get-Item -LiteralPath $argName -Force -ErrorAction SilentlyContinue)
			}
			if ($argObjects.Count -eq 0) { throw }
			foreach ($argObj in $argObjects) {
				$argName = Add-LongPrefix $argObj.FullName
				if ($argObj.PSIsContainer) {
					if ((-not $pathArgs.Contains($argName)) -and (-not $Files)) {
						$pathArgs[$argName] = $null
					}
				} else {
					if ((-not $sep) -and ($script:algorithms.ContainsKey($argObj.Extension))) {
						if (-not $fileArgs.Contains($argName)) { $fileArgs[$argName] = $argObj }
					} elseif (-not ($pathArgs.Contains($argName) -or $Files)) {
						$pathArgs[$argName] = $null
					}
				}
			}
		} catch {
			Write-Host ('Path not found: ' + $argRaw) -ForegroundColor Red
			$argErr = $true
			if ($Paths -or $Files) { continue }
			Invoke-Pause
			exit 2
		}
	}
	if ($fileArgs.Count -gt 0) { $script:files = @($fileArgs.Values) }
	if ($pathArgs.Count -gt 0) { $script:paths = @($pathArgs.Keys) }
	if ($argErr -and $ErrorPause) { Invoke-Pause }
}

function Add-LongPrefix {
	param(
		[string]$Path
	)
	if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
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
	if ($script:opt.SysResolution) {
		return Add-LongPrefix ([System.IO.Path]::GetFullPath((Remove-LongPrefix $Path)))
	}
	$normal = (Remove-LongPrefix $Path).Replace('/', '\')
	$unc = $normal.StartsWith('\\', [System.StringComparison]::Ordinal)
	$normal = $script:regexDupSep.Replace($normal, '\')
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
	$segmBuilder = [System.Text.StringBuilder]::new()
	$chars = $relative.ToCharArray()
	$skip = 0
	$idx = $chars.Length - 1
	while ($idx -ge 0) {
		$sep = $false
		$chr = $chars[$idx]
		if ($chr -eq [char]'\') {
			$sep = $true
		} else {
			[void]$segmBuilder.Append($chr)
		}
		if ($sep -or ($idx -eq 0)) {
			if ($segmBuilder.Length -gt 0) {
				$segm = $segmBuilder.ToString()
				if ($segm -ne '.') {
					if ($segm -eq '..') {
						$skip++
					} elseif ($skip -gt 0) {
						$skip--
					} else {
						[void]$pathBuilder.Append($segm)
						if ($sep) { [void]$pathBuilder.Append([char]'\') }
					}
				}
				[void]$segmBuilder.Clear()
			}
		}
		$idx--
	}
	$chars = $pathBuilder.ToString().ToCharArray()
	[Array]::Reverse($chars)
	$relative = -join $chars
	return Add-LongPrefix ([System.IO.Path]::Combine($root, $relative.TrimStart('\')))
}

function Get-FileEncoding {
	param(
		[string]$Path
	)
	$reader = $null
	try {
		$reader = [System.IO.StreamReader]::new($Path, $script:utf, $true)
		[void]$reader.ReadToEnd()
		return $reader.CurrentEncoding
	} catch [System.Text.DecoderFallbackException] {
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
				Write-Err $_
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
		Write-Err $_
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
	$searchErr = @()
	Get-ChildItem -LiteralPath $Paths -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +searchErr | ForEach-Object { $newFiles[(Add-LongPrefix $_.FullName)] = $null }
	foreach ($err in $searchErr) { Write-Err $err }
	if ($newFiles.Count -gt 0) {
		Write-Log ('Files found: ' + $newFiles.Count)
	} else {
		Write-Log 'Files not found!'
		$script:stat.SearchEmpty++
	}
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

function Get-FileTime {
	param(
		[TimeUnit]$Unit,
		[int]$Time,
		[DateTime]$Now
	)
	try {
		switch ($Unit) {
			([TimeUnit]::Minutes) { return $Now.AddMinutes(-$Time) }
			([TimeUnit]::Hours) { return $Now.AddHours(-$Time) }
			([TimeUnit]::Days) { return $Now.AddDays(-$Time) }
			([TimeUnit]::Months) { return $Now.AddMonths(-$Time) }
			([TimeUnit]::Years) { return $Now.AddYears(-$Time) }
		}
	} catch {
		return $null
	}
}

function Test-FileExist {
	param(
		[string]$Path
	)
	if ([System.IO.File]::Exists($Path)) { return $true }
	try {
		return -not ([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::Directory)
	} catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
		return $false
	} catch {
		Write-Err $_
	}
	return $null
}

function Test-FileTime {
	param(
		[string]$Path,
		[DateTime]$Time
	)
	try {
		return ([System.IO.File]::GetLastWriteTime($Path) -ge $Time) -or ([System.IO.File]::GetCreationTime($Path) -ge $Time)
	} catch {
		Write-Err $_
	}
	return $false
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
		[string]$FilePath,
		[string[]]$Paths
	)
	foreach ($path in $Paths) {
		if (($FilePath -ieq $path) -or $FilePath.StartsWith($path.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
	}
	return $false
}

function Test-Time {
	param(
		[TimeUnit]$Unit,
		[int]$Value
	)
	if ($Value -le 0) { throw }
	if ($null -eq (Get-FileTime $Unit $Value (Get-Date))) { throw }
}

function Test-Mask {
	param(
		[string]$Value,
		[switch]$Skip
	)
	$masks = [System.Collections.Generic.List[string]]::new()
	foreach ($mask in @($Value -split '\|' | Where-Object { $_ -ne '' })) {
		try {
			[void]('' -like $mask)
			$masks.Add($mask)
		} catch {
			if (-not $Skip) { throw }
		}
	}
	if ($masks.Count -eq 0) { throw }
	return $masks -join '|'
}

function Write-Log {
	param(
		[string]$Value,
		[ConsoleColor]$ForegroundColor,
		[DateTime]$Now,
		[switch]$NoHost
	)
	if (-not $NoHost) {
		if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
			Write-Host $Value -ForegroundColor $ForegroundColor
		} else {
			Write-Host $Value
		}
	}
	if ([string]::IsNullOrEmpty($Value)) {
		$script:log.Add('')
	} else {
		if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-Date }
		$script:log.Add('[' + $Now.ToString('yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Value)
	}
}

function Write-Err {
	param(
		[System.Management.Automation.ErrorRecord]$Err
	)
	if ($Err.Exception -and $Err.Exception.InnerException) {
		$msg = $Err.Exception.InnerException.Message
	} else {
		$msg = $Err.ToString()
	}
	Write-Log ('Execution error: ' + $msg) -ForegroundColor Red
	$script:stat.SysErr++
}

function Invoke-ClearHost {
	if (-not $script:opt.Quiet) { Clear-Host }
}

function Invoke-Pause {
	if (-not $script:opt.Quiet) {
		Write-Host ''
		pause
	}
}

$startTime = Get-Date
Parse-Args $env:BATARGS
$script:auto = $script:paths.Count -eq 0
$batFile = Get-LongPath $env:BATFILE
$batDir = Get-LongPath $env:BATDIR
if (($script:files.Count -eq 0) -and (-not $script:opt.NoAuto)) {
	$script:files = @(Get-ChildItem -LiteralPath $batDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $script:algorithms.ContainsKey($_.Extension) })
}
if ($script:auto -and $script:opt.NoAuto) {
	$script:opt.MissingEntries = $false
	if ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) { $script:opt.VerifyHashes = [HashMode]::No }
}
if ($script:opt.ShowMenu) {
	Show-Menu
	$startTime = Get-Date
}
if ($script:files.Count -eq 0) {
	Write-Host 'Checksum files not found!' -ForegroundColor Red
	Write-Host 'Supported file formats: .sfv, .md5, .sha1, .sha256, .sha384, .sha512' -ForegroundColor Red
	Invoke-Pause
	exit 1
}
Invoke-ClearHost
Write-Log 'Check started' -Now $startTime -NoHost
Write-Log '' -NoHost
$regexOptions = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$regexPatterns = @{
	'.sfv' = [regex]::new('^(.*?)\s+([a-f0-9]{8})$', $regexOptions)
	'.md5' = [regex]::new('^([a-f0-9]{32})\s+\*?(.*)$', $regexOptions)
	'.sha1' = [regex]::new('^([a-f0-9]{40})\s+\*?(.*)$', $regexOptions)
	'.sha256' = [regex]::new('^([a-f0-9]{64})\s+\*?(.*)$', $regexOptions)
	'.sha384' = [regex]::new('^([a-f0-9]{96})\s+\*?(.*)$', $regexOptions)
	'.sha512' = [regex]::new('^([a-f0-9]{128})\s+\*?(.*)$', $regexOptions)
}
$entInclude = @()
if (-not [string]::IsNullOrEmpty($script:opt.EntInclude)) {
	$entInclude = @($script:opt.EntInclude -split '\|' | Where-Object { $_ -ne '' })
}
$entExclude = @()
if (-not [string]::IsNullOrEmpty($script:opt.EntExclude)) {
	$entExclude = @($script:opt.EntExclude -split '\|' | Where-Object { $_ -ne '' })
}
$entTime = $null
if ($script:opt.EntTime -gt 0) {
	$entTime = Get-FileTime $script:opt.EntTimeUnit $script:opt.EntTime $startTime
}
$hashInclude = @()
if (-not [string]::IsNullOrEmpty($script:opt.HashInclude)) {
	$hashInclude = @($script:opt.HashInclude -split '\|' | Where-Object { $_ -ne '' })
}
$hashExclude = @()
if (-not [string]::IsNullOrEmpty($script:opt.HashExclude)) {
	$hashExclude = @($script:opt.HashExclude -split '\|' | Where-Object { $_ -ne '' })
}
$hashTime = $null
if ($script:opt.HashTime -gt 0) {
	$hashTime = Get-FileTime $script:opt.HashTimeUnit $script:opt.HashTime $startTime
}
$hashes = @{}
$updObjects = [ordered]@{}
$newFiles = [ordered]@{}
if (($script:opt.MissingEntries -or ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths)) -and (-not $script:auto)) {
	if ($script:paths.Count -eq 1) {
		Write-Log ('Search path: ' + (Remove-LongPrefix $script:paths[0]))
	} else {
		Write-Log 'Search paths:'
		foreach ($path in $script:paths) {
			Write-Log (Remove-LongPrefix $path)
		}
	}
	if ($script:opt.MissingEntries) {
		$script:stat.SysErr = 0
		$newFiles = Get-NewFiles $script:paths
		$script:stat.GlobalErr += $script:stat.SysErr
		if ($script:stat.SysErr) { Write-Log ('Execution errors: ' + $script:stat.SysErr) -ForegroundColor Red }
	}
	Write-Log ''
}
foreach ($file in $script:files) {
	$script:stat.SysErr = 0
	$fileName = Add-LongPrefix $file.FullName
	$fileDir = Add-LongPrefix $file.DirectoryName
	$fileExt = $file.Extension
	$fileStat = [PSCustomObject]@{
		EntChecked = 0
		Skipped = 0
		DuplicateEntries = 0
		MissingEntries = 0
		MissingFiles = 0
		HashCalc = 0
		HashNotCalc = 0
		HashMismatch = 0
	}
	$skipStat = $false
	Write-Log ('Checking checksum file: ' + (Remove-LongPrefix $fileName))
	if (($script:opt.MissingEntries -or ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths)) -and $script:auto) {
		$newFiles = [ordered]@{}
		$baseDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
		if ([System.IO.Directory]::Exists($baseDir)) {
			$script:paths = @($baseDir)
		} else {
			$script:paths = @($fileDir)
		}
		Write-Log ('Search path: ' + (Remove-LongPrefix $script:paths[0]))
		if ($script:opt.MissingEntries) { $newFiles = Get-NewFiles $script:paths }
	}
	$algorithm = $script:algorithms[$fileExt]
	$pattern = $regexPatterns[$fileExt]
	$entries = [ordered]@{}
	$newEntries = [ordered]@{}
	$keys = @{}
	try {
		$encoding = Get-FileEncoding $fileName
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
					if (($algorithm -ieq 'CRC32') -and $line.TrimStart().StartsWith(';', [System.StringComparison]::Ordinal) -and (-not (Test-FileExist $entPath))) {
						$ent = $null
					}
				} catch {
					$ent = $null
				}
			}
			if (-not [string]::IsNullOrEmpty($ent)) {
				$fileStat.EntChecked++
				$entKey = $entPath
				if ($keys.ContainsKey($entKey)) {
					$fileStat.DuplicateEntries++
					if ($script:opt.DuplicateEntries) {
						Write-Log ('Duplicate entry: ' + $ent) -ForegroundColor Cyan
						continue
					} else {
						$entKey = '<DUP' + $fileStat.DuplicateEntries + '>'
					}
				} else {
					$keys[$entKey] = $null
				}
				$fileExist = Test-FileExist $entPath
				if ($fileExist) {
					$entLine = $line
					if ($script:opt.VerifyHashes -ne [HashMode]::No) {
						$verifyHash = $true
						if (($null -ne $hashTime) -and (-not (Test-FileTime $entPath $hashTime))) { $verifyHash = $false }
						if ($verifyHash -and ($hashInclude.Count -gt 0) -and (-not (Test-FileMask $entPath $hashInclude $true))) { $verifyHash = $false }
						if ($verifyHash -and ($hashExclude.Count -gt 0) -and (-not (Test-FileMask $entPath $hashExclude $false))) { $verifyHash = $false }
						if ($verifyHash -and ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) -and (-not (Test-FilePath $entPath $script:paths))) { $verifyHash = $false }
						if ($verifyHash) {
							$hashKey = '<' + $algorithm + '>' + $entPath
							$hash = $hashes[$hashKey]
							if ($null -eq $hash) {
								$hash = Get-HashValue $entPath $algorithm
								if ($null -ne $hash) { $hashes[$hashKey] = $hash }
							}
							if ($null -eq $hash) {
								Write-Log ('Failed to calculate hash: ' + $ent) -ForegroundColor Red
								$fileStat.HashNotCalc++
							} else {
								if ($entHash -ine $hash) {
									Write-Log ('Hash mismatch: ' + $ent) -ForegroundColor Red
									$fileStat.HashMismatch++
									$entLine = Get-EntLine $ent $hash $algorithm
								} elseif ($script:opt.Verbose) {
									Write-Log ('Hash matched: ' + $ent) -ForegroundColor Green
								}
								$fileStat.HashCalc++
							}
						}
					}
					$entries[$entKey] = $entLine
				} elseif (($null -ne $fileExist) -and $script:opt.MissingFiles) {
					Write-Log ('Missing file: ' + $ent) -ForegroundColor Magenta
					$fileStat.MissingFiles++
				} else {
					$entries[$entKey] = $line
				}
			} else {
				$fileStat.Skipped++
				$entries['<SKIP' + $fileStat.Skipped + '>'] = $line
			}
		}
		foreach ($entPath in $newFiles.Keys) {
			if ($entries.Contains($entPath)) { continue }
			if (($entPath -ieq $fileName) -or ($entPath -ieq $batFile)) { continue }
			if (($null -ne $entTime) -and (-not (Test-FileTime $entPath $entTime))) { continue }
			if (($entInclude.Count -gt 0) -and (-not (Test-FileMask $entPath $entInclude $true))) { continue }
			if (($entExclude.Count -gt 0) -and (-not (Test-FileMask $entPath $entExclude $false))) { continue }
			$baseDir = $fileDir.TrimEnd('\') + '\'
			if ((-not $script:opt.AbsolutePaths) -and $entPath.StartsWith($baseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
				$ent = $entPath.Substring($baseDir.Length).TrimStart('\')
			} else {
				$ent = Remove-LongPrefix $entPath
			}
			Write-Log ('Missing entry: ' + $ent) -ForegroundColor Yellow
			$fileStat.MissingEntries++
			$newEntries[$entPath] = $ent
		}
	} catch {
		Write-Err $_
		Write-Log 'Failed to check checksum file!' -ForegroundColor Red
		$script:stat.FilesNotChecked++
		$skipStat = $true
	}
	$listErr = $false
	$warnings = $false
	$deleted = 0
	if ($script:stat.SysErr) {
		$script:stat.CheckErr += $script:stat.SysErr
		Write-Log ('Execution errors: ' + $script:stat.SysErr) -ForegroundColor Red
	}
	if ($skipStat) {
		Write-Log ''
		continue
	}
	if ($fileStat.EntChecked) {
		Write-Log ('Entries checked: ' + $fileStat.EntChecked)
		$script:stat.EntChecked += $fileStat.EntChecked
	} else {
		Write-Log 'Entries not found in checksum file!' -ForegroundColor Yellow
		$script:stat.FilesEmpty++
		$warnings = $true
	}
	if ($script:opt.MissingEntries -and ((($newFiles.Count -eq 0) -and $script:auto) -or (($script:files.Count -eq 1) -and $script:stat.SearchEmpty))) {
		Write-Log 'Files not found in search paths!' -ForegroundColor Yellow
		$warnings = $true
	}
	if ($fileStat.Skipped) {
		Write-Log ('Lines skipped: ' + $fileStat.Skipped)
		$script:stat.Skipped += $fileStat.Skipped
	}
	if ($script:opt.DuplicateEntries -and $fileStat.DuplicateEntries) {
		Write-Log ('Duplicate entries: ' + $fileStat.DuplicateEntries) -ForegroundColor Cyan
		$script:stat.DuplicateEntries += $fileStat.DuplicateEntries
		$deleted += $fileStat.DuplicateEntries
		$listErr = $true
	}
	if ($fileStat.MissingFiles) {
		Write-Log ('Missing files: ' + $fileStat.MissingFiles) -ForegroundColor Magenta
		$script:stat.MissingFiles += $fileStat.MissingFiles
		$deleted += $fileStat.MissingFiles
		$listErr = $true
	}
	if ($fileStat.MissingEntries) {
		Write-Log ('Missing entries: ' + $fileStat.MissingEntries) -ForegroundColor Yellow
		$script:stat.MissingEntries += $fileStat.MissingEntries
		$listErr = $true
	}
	if ($fileStat.HashCalc) {
		Write-Log ('Hashes calculated: ' + $fileStat.HashCalc)
		$script:stat.HashCalc += $fileStat.HashCalc
	}
	if ($fileStat.HashNotCalc) {
		Write-Log ('Hashes not calculated: ' + $fileStat.HashNotCalc) -ForegroundColor Red
		$script:stat.HashNotCalc += $fileStat.HashNotCalc
	}
	if ($fileStat.HashMismatch) {
		Write-Log ('Hash mismatches: ' + $fileStat.HashMismatch) -ForegroundColor Red
		$script:stat.HashMismatch += $fileStat.HashMismatch
		$listErr = $true
	}
	if ($listErr -and (-not ($script:opt.Safe -and ($script:stat.SysErr -or $script:stat.GlobalErr)))) {
		$updObjects[$fileName] = [PSCustomObject]@{
			Algorithm = $algorithm
			Encoding = $encoding
			Entries = $entries
			NewEntries = $newEntries
			EntDeleted = $deleted
			EntUpdated = $fileStat.HashMismatch
			EntAdded = 0
			EntNotAdded = 0
		}
	}
	if ($script:stat.SysErr -or $script:stat.GlobalErr) {
		Write-Log 'Checksum file checked with errors!' -ForegroundColor Red
		$script:stat.FilesCheckedErr++
	} else {
		if (-not ($listErr -or $warnings)) {
			Write-Log 'Checksum file checked successfully!' -ForegroundColor Green
		}
		$script:stat.FilesChecked++
	}
	Write-Log ''
}
Write-Log 'Check completed!'
$script:stat.CheckErr += $script:stat.GlobalErr
if ($script:files.Count -ne 1) {
	Write-Log ''
	$listErr = $false
	$warnings = $false
	if ($script:stat.CheckErr) { Write-Log ('Execution errors: ' + $script:stat.CheckErr) -ForegroundColor Red }
	if ($script:stat.FilesChecked) { Write-Log ('Checksum files checked: ' + $script:stat.FilesChecked) }
	if ($script:stat.FilesCheckedErr) { Write-Log ('Checksum files checked with errors: ' + $script:stat.FilesCheckedErr) -ForegroundColor Red }
	if ($script:stat.FilesNotChecked) { Write-Log ('Not checked checksum files: ' + $script:stat.FilesNotChecked) -ForegroundColor Red }
	if ($script:stat.EntChecked) { Write-Log ('Entries checked: ' + $script:stat.EntChecked) }
	if ($script:stat.FilesEmpty) {
		if ($script:stat.EntChecked) {
			Write-Log ('Entries not found in checksum file: ' + $script:stat.FilesEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Entries not found in checksum files!' -ForegroundColor Yellow
		}
		$warnings = $true
	}
	if ($script:stat.SearchEmpty) {
		if ($script:auto) {
			Write-Log ('Files not found in search paths: ' + $script:stat.SearchEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Files not found in search paths!' -ForegroundColor Yellow
		}
		$warnings = $true
	}
	if ($script:stat.Skipped) { Write-Log ('Lines skipped: ' + $script:stat.Skipped) }
	if ($script:stat.DuplicateEntries) {
		Write-Log ('Duplicate entries: ' + $script:stat.DuplicateEntries) -ForegroundColor Cyan
		$listErr = $true
	}
	if ($script:stat.MissingFiles) {
		Write-Log ('Missing files: ' + $script:stat.MissingFiles) -ForegroundColor Magenta
		$listErr = $true
	}
	if ($script:stat.MissingEntries) {
		Write-Log ('Missing entries: ' + $script:stat.MissingEntries) -ForegroundColor Yellow
		$listErr = $true
	}
	if ($script:stat.HashCalc) { Write-Log ('Hashes calculated: ' + $script:stat.HashCalc) }
	if ($script:stat.HashNotCalc) { Write-Log ('Hashes not calculated: ' + $script:stat.HashNotCalc) -ForegroundColor Red }
	if ($script:stat.HashMismatch) {
		Write-Log ('Hash mismatches: ' + $script:stat.HashMismatch) -ForegroundColor Red
		$listErr = $true
	}
	if ($script:stat.CheckErr -or $script:stat.GlobalErr) {
		Write-Log 'Check completed with errors!' -ForegroundColor Red
	} elseif (-not ($listErr -or $warnings)) {
		Write-Log 'Check completed successfully!' -ForegroundColor Green
	}
}
$finalPause = $true
if ($updObjects.Count -gt 0) {
	if ($script:opt.UpdateMsg) {
		Write-Host ''
		$msg = $true
		while ($msg) {
			if ($script:stat.CheckErr -or $script:stat.GlobalErr) {
				Write-Host 'Update' -ForegroundColor Red -NoNewline
			} else {
				Write-Host 'Update' -ForegroundColor Green -NoNewline
			}
			Write-Host ' checksum files? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$script:opt.Update = $false
					$msg = $false
					break
				}
				'^(y|yes)$' {
					$script:opt.Update = $true
					$msg = $false
					break
				}
				'^(n|no)$' {
					$script:opt.Update = $false
					$msg = $false
					break
				}
			}
		}
		$finalPause = $false
	}
	if ($script:opt.Update) {
		Write-Log ''
		Write-Log 'Update started' -NoHost
		Write-Log '' -NoHost
		foreach ($fileName in $updObjects.Keys) {
			$script:stat.SysErr = 0
			$updObj = $updObjects[$fileName]
			$tempFile = $fileName + '_' + [System.Guid]::NewGuid().ToString('N') + '.tmp'
			$bakIdx = 0
			$bakFile = $fileName + '.bak'
			$bakExist = $false
			$skipStat = $false
			Write-Log ('Updating checksum file: ' + (Remove-LongPrefix $fileName))
			try {
				foreach ($entPath in $updObj.NewEntries.Keys) {
					$ent = $updObj.NewEntries[$entPath]
					$hashKey = '<' + $updObj.Algorithm + '>' + $entPath
					$hash = $hashes[$hashKey]
					if ($null -eq $hash) {
						$hash = Get-HashValue $entPath $updObj.Algorithm
						if ($null -ne $hash) { $hashes[$hashKey] = $hash }
					}
					if ($null -eq $hash) {
						Write-Log ('Failed to calculate hash: ' + $ent) -ForegroundColor Red
						if ($script:opt.Safe) { throw [CustomException]::new('Update aborted!') }
						$updObj.EntNotAdded++
					} else {
						$updObj.Entries[$entPath] = Get-EntLine $ent $hash $updObj.Algorithm
						if ($script:opt.Verbose) { Write-Log ('Hash calculated: ' + $ent) -ForegroundColor Green }
						$updObj.EntAdded++
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
			} catch [CustomException] {
				Write-Log $_.Exception.Message -ForegroundColor Red
				$script:stat.FilesNotUpdated++
				$skipStat = $true
			} catch {
				Write-Err $_
				Write-Log 'Failed to update checksum file!' -ForegroundColor Red
				if ($bakExist -and (-not [System.IO.File]::Exists($fileName)) -and [System.IO.File]::Exists($bakFile)) {
					try {
						[System.IO.File]::Move($bakFile, $fileName)
						Write-Log 'File restored from backup!' -ForegroundColor Red
					} catch {
						Write-Err $_
						Write-Log 'File not restored from backup!' -ForegroundColor Red
					}
				}
				$script:stat.FilesNotUpdated++
				$skipStat = $true
			} finally {
				if ([System.IO.File]::Exists($tempFile)) {
					try { [System.IO.File]::Delete($tempFile) } catch {}
				}
			}
			if ($script:stat.SysErr) {
				$script:stat.UpdateErr += $script:stat.SysErr
				Write-Log ('Execution errors: ' + $script:stat.SysErr) -ForegroundColor Red
			}
			if ($skipStat) {
				Write-Log ''
				continue
			}
			if ($updObj.EntDeleted) {
				Write-Log ('Entries deleted: ' + $updObj.EntDeleted)
				$script:stat.EntDeleted += $updObj.EntDeleted
			}
			if ($updObj.EntUpdated) {
				Write-Log ('Entries updated: ' + $updObj.EntUpdated)
				$script:stat.EntUpdated += $updObj.EntUpdated
			}
			if ($updObj.EntAdded) {
				Write-Log ('Entries added: ' + $updObj.EntAdded)
				$script:stat.EntAdded += $updObj.EntAdded
			}
			if ($updObj.EntNotAdded) {
				Write-Log ('Entries not added: ' + $updObj.EntNotAdded) -ForegroundColor Red
				$script:stat.EntNotAdded += $updObj.EntNotAdded
			}
			if ($script:stat.SysErr) {
				Write-Log 'Checksum file updated with errors!' -ForegroundColor Red
				$script:stat.FilesUpdatedErr++
			} else {
				Write-Log 'Checksum file updated successfully!' -ForegroundColor Green
				$script:stat.FilesUpdated++
			}
			Write-Log ''
		}
		Write-Log 'Update completed!'
		if ($updObjects.Count -ne 1) {
			Write-Log ''
			if ($script:stat.UpdateErr) { Write-Log ('Execution errors: ' + $script:stat.UpdateErr) -ForegroundColor Red }
			if ($script:stat.FilesUpdated) { Write-Log ('Checksum files updated: ' + $script:stat.FilesUpdated) }
			if ($script:stat.FilesUpdatedErr) { Write-Log ('Checksum files updated with errors: ' + $script:stat.FilesUpdatedErr) -ForegroundColor Red }
			if ($script:stat.FilesNotUpdated) { Write-Log ('Checksum files not updated: ' + $script:stat.FilesNotUpdated) -ForegroundColor Red }
			if ($script:stat.EntDeleted) { Write-Log ('Entries deleted: ' + $script:stat.EntDeleted) }
			if ($script:stat.EntUpdated) { Write-Log ('Entries updated: ' + $script:stat.EntUpdated) }
			if ($script:stat.EntAdded) { Write-Log ('Entries added: ' + $script:stat.EntAdded) }
			if ($script:stat.EntNotAdded) { Write-Log ('Entries not added: ' + $script:stat.EntNotAdded) -ForegroundColor Red }
			if ($script:stat.UpdateErr) {
				Write-Log 'Update completed with errors!' -ForegroundColor Red
			} else {
				Write-Log 'Update completed successfully!' -ForegroundColor Green
			}
		}
		$finalPause = $true
	}
}
if ($script:opt.LogMsg) {
	Write-Host ''
	$msg = $true
	while ($msg) {
		Write-Host 'Save check log? (Yes / ' -NoNewline
		Write-Host '[No]' -ForegroundColor Green -NoNewline
		$read = Read-Host ')'
		switch -Regex ($read.Trim()) {
			'^$' {
				$script:opt.Log = $false
				$msg = $false
				break
			}
			'^(y|yes)$' {
				$script:opt.Log = $true
				$msg = $false
				break
			}
			'^(n|no)$' {
				$script:opt.Log = $false
				$msg = $false
				break
			}
		}
	}
	$finalPause = $false
}
$logErr = $false
if ($script:opt.Log) {
	Write-Host ''
	$logName = 'ChecksumListChecker_' + $startTime.ToString('yyyy-MM-dd_HH-mm-ss')
	$tempFile = [System.IO.Path]::Combine($batDir, ($logName + '_' + [System.Guid]::NewGuid().ToString('N') + '.tmp'))
	$logIdx = 0
	$logFile = [System.IO.Path]::Combine($batDir, $logName + '.txt')
	try {
		[System.IO.File]::WriteAllLines($tempFile, $script:log, $script:utf)
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
		Write-Err $_
		Write-Host 'Failed to save check log!' -ForegroundColor Red
		$logErr = $true
	} finally {
		if ([System.IO.File]::Exists($tempFile)) {
			try { [System.IO.File]::Delete($tempFile) } catch {}
		}
	}
	$finalPause = $true
}
if ($finalPause) { Invoke-Pause }

$exit = 0
if ($script:stat.CheckErr) { $exit = $exit -bor 4 }
if ($script:stat.UpdateErr) { $exit = $exit -bor 8 }
if ($script:stat.DuplicateEntries) { $exit = $exit -bor 16 }
if ($script:stat.MissingFiles) { $exit = $exit -bor 16 }
if ($script:stat.MissingEntries) { $exit = $exit -bor 16 }
if ($script:stat.HashMismatch) { $exit = $exit -bor 32 }
if ($script:stat.FilesEmpty) { $exit = $exit -bor 64 }
if ($script:stat.SearchEmpty) { $exit = $exit -bor 64 }
if ($logErr) { $exit = $exit -bor 128 }
exit $exit
