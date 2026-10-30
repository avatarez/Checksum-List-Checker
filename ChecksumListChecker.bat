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

$script:opts = [PSCustomObject]@{
	ShowMenu = $true
	DuplicateEntries = $true
	MissingFiles = $true
	MissingEntries = $true
	VerifyHashes = [HashMode]::No
	EntInclude = @()
	EntExclude = @()
	EntTimeUnit = $null
	EntTime = 0
	HashInclude = @()
	HashExclude = @()
	HashTimeUnit = $null
	HashTime = 0
	Verbose = $true
	AbsPaths = $false
	SysRes = $true
	Update = $false
	UpdateMsg = $true
	Log = $false
	LogMsg = $true
	Safe = $false
	NoAuto = $false
	Batch = $false
}

$script:stats = [PSCustomObject]@{
	ExecutionErr = 0
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
	EntSkipped = 0
	DuplicateEntries = 0
	MissingEntries = 0
	MissingFiles = 0
	HashCalculated = 0
	HashNotCalculated = 0
	HashMismatches = 0
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
		Invoke-ClearHost
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
			if ($script:opts.NoAuto) {
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
		if ($script:opts.DuplicateEntries) {
			Write-Host '2.  Check for ' -NoNewline
			Write-Host 'duplicate entries' -ForegroundColor Cyan -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '2.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'duplicate entries' -ForegroundColor DarkCyan -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:opts.MissingFiles) {
			Write-Host '3.  Check for ' -NoNewline
			Write-Host 'missing files' -ForegroundColor Magenta -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '3.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing files' -ForegroundColor DarkMagenta -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:auto -and $script:opts.NoAuto) {
			Write-Host '4.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing entries' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Not available' -ForegroundColor DarkGray
		} elseif ($script:opts.MissingEntries) {
			Write-Host '4.  Check for ' -NoNewline
			Write-Host 'missing entries' -ForegroundColor Yellow -NoNewline
			Write-Host ': Yes'
		} else {
			Write-Host '4.  Check for ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'missing entries' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': No' -ForegroundColor DarkGray
		}
		if ($script:opts.VerifyHashes -eq [HashMode]::All) {
			Write-Host '5.  Verify ' -NoNewline
			Write-Host 'hashes' -ForegroundColor Red -NoNewline
			Write-Host ' (slow): All'
		} elseif ($script:opts.VerifyHashes -eq [HashMode]::SearchPaths) {
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
		if ($script:opts.MissingEntries -or ($script:opts.VerifyHashes -ne [HashMode]::No)) {
			if ($script:opts.Verbose) {
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
		if ($script:opts.MissingEntries) {
			if ($script:opts.AbsPaths) {
				Write-Host '8.  Missing entries path mode: Absolute'
			} else {
				Write-Host '8.  Missing entries path mode: Relative'
			}
		} else {
			Write-Host '8.  Missing entries path mode: Not available' -ForegroundColor DarkGray
		}
		if ($script:opts.SysRes) {
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
				$script:opts.DuplicateEntries = -not $script:opts.DuplicateEntries
				break
			}
			'3' {
				$script:opts.MissingFiles = -not $script:opts.MissingFiles
				break
			}
			'4' {
				if (-not ($script:auto -and $script:opts.NoAuto)) { $script:opts.MissingEntries = -not $script:opts.MissingEntries }
				break
			}
			'5' {
				if ($script:opts.VerifyHashes -eq [HashMode]::No) {
					$script:opts.VerifyHashes = [HashMode]::All
				} elseif ($script:opts.VerifyHashes -eq [HashMode]::All) {
					if ($script:auto -and $script:opts.NoAuto) {
						$script:opts.VerifyHashes = [HashMode]::No
					} else {
						$script:opts.VerifyHashes = [HashMode]::SearchPaths
					}
				} else {
					$script:opts.VerifyHashes = [HashMode]::No
				}
				break
			}
			'6' {
				Show-Filters
				break
			}
			'7' {
				if ($script:opts.MissingEntries -or ($script:opts.VerifyHashes -ne [HashMode]::No)) { $script:opts.Verbose = -not $script:opts.Verbose }
				break
			}
			'8' {
				if ($script:opts.MissingEntries) { $script:opts.AbsPaths = -not $script:opts.AbsPaths }
				break
			}
			'9' {
				$script:opts.SysRes = -not $script:opts.SysRes
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
		Invoke-ClearHost
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:opts.MissingEntries) {
			Write-Host 'Missing entries check filter' -ForegroundColor Yellow
			Write-Host ''
			if ($script:opts.EntInclude) {
				Write-Host ('1. Include file mask: ' + ($script:opts.EntInclude -join '|'))
			} else {
				Write-Host '1. Include file mask: None' -ForegroundColor DarkGray
			}
			if ($script:opts.EntExclude) {
				Write-Host ('2. Exclude file mask: ' + ($script:opts.EntExclude -join '|'))
			} else {
				Write-Host '2. Exclude file mask: None' -ForegroundColor DarkGray
			}
			if ($script:opts.EntTime -gt 0) {
				Write-Host ('3. File modification time (' + (Get-TimeUnit $script:opts.EntTimeUnit) + '): ' + $script:opts.EntTime)
			} else {
				Write-Host '3. File modification time: None' -ForegroundColor DarkGray
			}
		} else {
			Write-Host 'Missing entries check filter' -ForegroundColor DarkYellow
			Write-Host ''
			Write-Host '1. Include file mask: Not available' -ForegroundColor DarkGray
			Write-Host '2. Exclude file mask: Not available' -ForegroundColor DarkGray
			Write-Host '3. File modification time: Not available' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:opts.VerifyHashes -ne [HashMode]::No) {
			Write-Host 'Hash verification filter' -ForegroundColor Red
			Write-Host ''
			if ($script:opts.HashInclude) {
				Write-Host ('4. Include file mask: ' + ($script:opts.HashInclude -join '|'))
			} else {
				Write-Host '4. Include file mask: None' -ForegroundColor DarkGray
			}
			if ($script:opts.HashExclude) {
				Write-Host ('5. Exclude file mask: ' + ($script:opts.HashExclude -join '|'))
			} else {
				Write-Host '5. Exclude file mask: None' -ForegroundColor DarkGray
			}
			if ($script:opts.HashTime -gt 0) {
				Write-Host ('6. File modification time (' + (Get-TimeUnit $script:opts.HashTimeUnit) + '): ' + $script:opts.HashTime)
			} else {
				Write-Host '6. File modification time: None' -ForegroundColor DarkGray
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
				if ($script:opts.MissingEntries) { Show-NewMask ([MaskMode]::EntInclude) }
				break
			}
			'2' {
				if ($script:opts.MissingEntries) { Show-NewMask ([MaskMode]::EntExclude) }
				break
			}
			'3' {
				if ($script:opts.MissingEntries) { Show-NewTime ([TimeMode]::EntTime) }
				break
			}
			'4' {
				if ($script:opts.VerifyHashes -ne [HashMode]::No) { Show-NewMask ([MaskMode]::HashInclude) }
				break
			}
			'5' {
				if ($script:opts.VerifyHashes -ne [HashMode]::No) { Show-NewMask ([MaskMode]::HashExclude) }
				break
			}
			'6' {
				if ($script:opts.VerifyHashes -ne [HashMode]::No) { Show-NewTime ([TimeMode]::HashTime) }
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
		$masks = @(Get-FileMask (Read-Host 'File mask') -ErrSkip)
	} catch {
		$masks = @()
	}
	switch ($maskMode) {
		([MaskMode]::EntInclude) {
			$script:opts.EntInclude = $masks
			break
		}
		([MaskMode]::EntExclude) {
			$script:opts.EntExclude = $masks
			break
		}
		([MaskMode]::HashInclude) {
			$script:opts.HashInclude = $masks
			break
		}
		([MaskMode]::HashExclude) {
			$script:opts.HashExclude = $masks
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
		Invoke-ClearHost
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
		Test-TimeValue $unit $time
	} catch {
		$unit = $null
		$time = 0
	}
	switch ($timeMode) {
		([TimeMode]::EntTime) {
			$script:opts.EntTimeUnit = $unit
			$script:opts.EntTime = $time
			break
		}
		([TimeMode]::HashTime) {
			$script:opts.HashTimeUnit = $unit
			$script:opts.HashTime = $time
			break
		}
	}
}

function Show-Paths {
	$restart = $true
	while ($restart) {
		$restart = $false
		Invoke-ClearHost
		Write-Host '╔═══════════════════════╗'
		Write-Host '║ Checksum List Checker ║'
		Write-Host '╚═══════════════════════╝'
		Write-Host ''
		if ($script:auto -and (-not $script:opts.NoAuto)) {
			if ($script:files.Count -eq 0) {
				Write-Host 'Checksum files: None' -ForegroundColor Red
				Write-Host ''
			} else {
				foreach ($file in $script:files) {
					Write-Host ('Checksum file: ' + (Remove-LongPrefix $file.FullName))
					$fileDir = Add-LongPrefix $file.DirectoryName
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
			if ($script:auto -and $script:opts.NoAuto) {
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
		$ret = $true
		while ($ret) {
			Write-Host 'Set new files and paths? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$ret = $false
					break
				}
				'^(y|yes)$' {
					Write-Host ''
					Show-NewPaths
					$restart = $true
					$ret = $false
					break
				}
				'^(n|no)$' {
					$ret = $false
					break
				}
			}
		}
	}
}

function Show-NewPaths {
	$read = Read-Host 'Checksum files'
	if ($read) { Parse-Args $read -Files }
	Write-Host ''
	$read = Read-Host 'Search paths'
	if ($read) {
		Parse-Args $read -Paths -ErrPause
		$script:auto = $script:paths.Count -eq 0
	} elseif (-not $script:auto) {
		$ret = $true
		while ($ret) {
			Write-Host ''
			Write-Host 'Clear search paths? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$ret = $false
					break
				}
				'^(y|yes)$' {
					$script:paths = @()
					$script:auto = $true
					$ret = $false
					break
				}
				'^(n|no)$' {
					$ret = $false
					break
				}
			}
		}
	}
	if ($script:auto -and $script:opts.NoAuto) {
		$script:opts.MissingEntries = $false
		if ($script:opts.VerifyHashes -eq [HashMode]::SearchPaths) { $script:opts.VerifyHashes = [HashMode]::No }
	}
}

function Parse-Args {
	param(
		[string]$Arguments,
		[switch]$Files,
		[switch]$Paths,
		[switch]$ErrPause
	)
	$argList = @([regex]::Matches($Arguments, '(?:[^\s"]|"[^"]*")+') | ForEach-Object { $_.Value })
	if ($argList.Count -eq 0) { return }
	$argErr = $false
	$fileArgs = [ordered]@{}
	$pathArgs = [ordered]@{}
	$sep = $Paths
	foreach ($argRaw in $argList) {
		$arg = $argRaw.Replace('"', '')
		if (-not ($Files -or $sep)) {
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
								$script:opts.Update = $false
								$script:opts.ShowMenu = $false
								$script:opts.UpdateMsg = $false
								$script:opts.LogMsg = $false
								break
							}
							'^(-u|--update)$' {
								$script:opts.Update = $true
								$script:opts.ShowMenu = $false
								$script:opts.UpdateMsg = $false
								$script:opts.LogMsg = $false
								break
							}
							'^(-d|--skip-duplicates)$' {
								$script:opts.DuplicateEntries = $false
								break
							}
							'^(-f|--skip-missing-files)$' {
								$script:opts.MissingFiles = $false
								break
							}
							'^(-e|--skip-missing-entries)$' {
								$script:opts.MissingEntries = $false
								break
							}
							'^(-h|--verify-all-hashes)$' {
								$script:opts.VerifyHashes = [HashMode]::All
								break
							}
							'^(-p|--verify-search-paths-hashes)$' {
								$script:opts.VerifyHashes = [HashMode]::SearchPaths
								break
							}
							'^(-v|--no-verbose)$' {
								$script:opts.Verbose = $false
								break
							}
							'^(-a|--absolute-paths)$' {
								$script:opts.AbsPaths = $true
								break
							}
							'^(-i|--internal-resolution)$' {
								$script:opts.SysRes = $false
								break
							}
							'^(-l|--save-log)$' {
								$script:opts.LogMsg = $false
								$script:opts.Log = $true
								break
							}
							'^(-s|--safe)$' {
								$script:opts.Safe = $true
								break
							}
							'^(-n|--no-auto)$' {
								$script:opts.NoAuto = $true
								break
							}
							'^(-b|--batch)$' {
								$script:opts.Batch = $true
								break
							}
							'^--missing-entries-include=$' {
								$script:opts.EntInclude = @(Get-FileMask $argVal)
								$script:opts.MissingEntries = $true
								break
							}
							'^--missing-entries-exclude=$' {
								$script:opts.EntExclude = @(Get-FileMask $argVal)
								$script:opts.MissingEntries = $true
								break
							}
							'^--missing-entries-minutes=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Minutes) $intVal
								$script:opts.EntTime = $intVal
								$script:opts.EntTimeUnit = [TimeUnit]::Minutes
								$script:opts.MissingEntries = $true
								break
							}
							'^--missing-entries-hours=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Hours) $intVal
								$script:opts.EntTime = $intVal
								$script:opts.EntTimeUnit = [TimeUnit]::Hours
								$script:opts.MissingEntries = $true
								break
							}
							'^--missing-entries-days=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Days) $intVal
								$script:opts.EntTime = $intVal
								$script:opts.EntTimeUnit = [TimeUnit]::Days
								$script:opts.MissingEntries = $true
								break
							}
							'^--missing-entries-months=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Months) $intVal
								$script:opts.EntTime = $intVal
								$script:opts.EntTimeUnit = [TimeUnit]::Months
								$script:opts.MissingEntries = $true
								break
							}
							'^--missing-entries-years=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Years) $intVal
								$script:opts.EntTime = $intVal
								$script:opts.EntTimeUnit = [TimeUnit]::Years
								$script:opts.MissingEntries = $true
								break
							}
							'^--hashes-include=$' {
								$script:opts.HashInclude = @(Get-FileMask $argVal)
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-exclude=$' {
								$script:opts.HashExclude = @(Get-FileMask $argVal)
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-minutes=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Minutes) $intVal
								$script:opts.HashTime = $intVal
								$script:opts.HashTimeUnit = [TimeUnit]::Minutes
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-hours=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Hours) $intVal
								$script:opts.HashTime = $intVal
								$script:opts.HashTimeUnit = [TimeUnit]::Hours
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-days=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Days) $intVal
								$script:opts.HashTime = $intVal
								$script:opts.HashTimeUnit = [TimeUnit]::Days
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-months=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Months) $intVal
								$script:opts.HashTime = $intVal
								$script:opts.HashTimeUnit = [TimeUnit]::Months
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-years=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Years) $intVal
								$script:opts.HashTime = $intVal
								$script:opts.HashTimeUnit = [TimeUnit]::Years
								if ($script:opts.VerifyHashes -eq [HashMode]::No) { $script:opts.VerifyHashes = [HashMode]::All }
								break
							}
							default { throw }
						}
					}
				} catch {
					Write-Host ('Invalid option: ' + $argRaw) -ForegroundColor Red
					$argErr = $true
				}
				continue
			}
		}
		try {
			$argObjects = @()
			if ((Remove-LongPrefix $arg) -match '[*?]') {
				$argName = [System.IO.Path]::GetFileName($arg)
				$argDir = [System.IO.Path]::GetDirectoryName($arg)
				if (-not $argDir) {
					$argDir = [System.IO.Directory]::GetCurrentDirectory()
				}
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
					if (-not ($Files -or $pathArgs.Contains($argName))) {
						$pathArgs[$argName] = $null
					}
				} else {
					if ((-not $sep) -and ($script:algorithms.ContainsKey($argObj.Extension))) {
						if (-not $fileArgs.Contains($argName)) { $fileArgs[$argName] = $argObj }
					} elseif (-not ($Files -or $pathArgs.Contains($argName))) {
						$pathArgs[$argName] = $null
					}
				}
			}
		} catch {
			Write-Host ('Path not found: ' + $argRaw) -ForegroundColor Red
			$argErr = $true
		}
	}
	if ($fileArgs.Count -gt 0) { $script:files = @($fileArgs.Values) }
	if ($pathArgs.Count -gt 0) { $script:paths = @($pathArgs.Keys) }
	if ($argErr) {
		if ($ErrPause) { Invoke-Pause }
		if (-not ($Files -or $Paths)) { exit 2 }
	}
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
	if ($script:opts.SysRes) {
		return Add-LongPrefix ([System.IO.Path]::GetFullPath((Remove-LongPrefix $Path)))
	}
	$normal = (Remove-LongPrefix $Path).Replace('/', '\')
	$unc = $normal.StartsWith('\\', [System.StringComparison]::Ordinal)
	$normal = $script:regexDupSep.Replace($normal, '\')
	if ($unc) { $normal = '\' + $normal }
	$root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($normal))
	if ($normal -eq $root) { return Add-LongPrefix $root }
	$root = $root.TrimEnd('\') + '\'
	$rootLen = $root.Length
	if ($normal.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
		$relative = $normal.Substring($rootLen).TrimStart('\')
	} elseif ($normal.StartsWith($root.Substring(0, 2), [System.StringComparison]::OrdinalIgnoreCase)) {
		$current = [System.IO.Path]::GetFullPath($root.Substring(0, 2) + '.')
		$relative = ([System.IO.Path]::Combine($current, $normal.Substring(2))).Substring($rootLen).TrimStart('\')
	} elseif ($normal.StartsWith('\', [System.StringComparison]::Ordinal)) {
		$relative = $normal.TrimStart('\')
	} else {
		$current = [System.IO.Directory]::GetCurrentDirectory()
		$relative = ([System.IO.Path]::Combine($current, $normal)).Substring($rootLen).TrimStart('\')
	}
	if (-not $relative) { return Add-LongPrefix $root }
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
		if ($Algorithm -eq 'CRC32') {
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
	if ($Algorithm -ne 'CRC32') {
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
		$script:stats.SearchEmpty++
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
		[int]$Value,
		[DateTime]$Now
	)
	try {
		switch ($Unit) {
			([TimeUnit]::Minutes) { return $Now.AddMinutes(-$Value) }
			([TimeUnit]::Hours) { return $Now.AddHours(-$Value) }
			([TimeUnit]::Days) { return $Now.AddDays(-$Value) }
			([TimeUnit]::Months) { return $Now.AddMonths(-$Value) }
			([TimeUnit]::Years) { return $Now.AddYears(-$Value) }
		}
	} catch {
		return $null
	}
}

function Get-FileMask {
	param(
		[string]$Value,
		[switch]$ErrSkip
	)
	$masks = [System.Collections.Generic.List[string]]::new()
	foreach ($mask in @($Value -split '\|' | Where-Object { $_ -ne '' })) {
		try {
			[void]('' -like $mask)
			$masks.Add($mask)
		} catch {
			if (-not $ErrSkip) { throw }
		}
	}
	if ($masks.Count -eq 0) { throw }
	return $masks
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
		if (($FilePath -eq $path) -or $FilePath.StartsWith($path.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
	}
	return $false
}

function Test-TimeValue {
	param(
		[TimeUnit]$Unit,
		[int]$Value
	)
	if ($Value -le 0) { throw }
	if ($null -eq (Get-FileTime $Unit $Value (Get-Date))) { throw }
}

function Write-Log {
	param(
		[string]$Text,
		[ConsoleColor]$ForegroundColor,
		[DateTime]$Now,
		[switch]$NoHost
	)
	if (-not $NoHost) {
		if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
			Write-Host $Text -ForegroundColor $ForegroundColor
		} else {
			Write-Host $Text
		}
	}
	if ($Text) {
		if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-Date }
		$script:log.Add('[' + $Now.ToString('yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Text)
	} else {
		$script:log.Add('')
	}
}

function Write-Err {
	param(
		[object]$Err
	)
	$errMsg = $null
	if ($Err.Exception -and $Err.Exception.InnerException) {
		$errMsg = $Err.Exception.InnerException.Message
	}
	if (-not $errMsg) {
		$errMsg = $Err.ToString()
	}
	Write-Log ('Execution error: ' + $errMsg) -ForegroundColor Red
	$script:stats.ExecutionErr++
}

function Invoke-ClearHost {
	if ($script:opts.Batch) { Write-Host '' } else { Clear-Host }
}

function Invoke-Pause {
	if (-not $script:opts.Batch) {
		Write-Host ''
		pause
	}
}

$startTime = Get-Date
Parse-Args $env:BATARGS -ErrPause
$script:auto = $script:paths.Count -eq 0
$batFile = Get-LongPath $env:BATFILE
$batDir = Get-LongPath $env:BATDIR
if (($script:files.Count -eq 0) -and (-not $script:opts.NoAuto)) {
	$script:files = @(Get-ChildItem -LiteralPath $batDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $script:algorithms.ContainsKey($_.Extension) })
}
if ($script:auto -and $script:opts.NoAuto) {
	$script:opts.MissingEntries = $false
	if ($script:opts.VerifyHashes -eq [HashMode]::SearchPaths) { $script:opts.VerifyHashes = [HashMode]::No }
}
if ($script:opts.ShowMenu) {
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
$entFileTime = $null
if ($script:opts.EntTime -gt 0) {
	$entFileTime = Get-FileTime $script:opts.EntTimeUnit $script:opts.EntTime $startTime
}
$hashFileTime = $null
if ($script:opts.HashTime -gt 0) {
	$hashFileTime = Get-FileTime $script:opts.HashTimeUnit $script:opts.HashTime $startTime
}
$hashes = @{}
$updObjects = [ordered]@{}
$newFiles = [ordered]@{}
if (($script:opts.MissingEntries -or ($script:opts.VerifyHashes -eq [HashMode]::SearchPaths)) -and (-not $script:auto)) {
	if ($script:paths.Count -eq 1) {
		Write-Log ('Search path: ' + (Remove-LongPrefix $script:paths[0]))
	} else {
		Write-Log 'Search paths:'
		foreach ($path in $script:paths) {
			Write-Log (Remove-LongPrefix $path)
		}
	}
	if ($script:opts.MissingEntries) {
		$script:stats.ExecutionErr = 0
		$newFiles = Get-NewFiles $script:paths
		$script:stats.GlobalErr += $script:stats.ExecutionErr
		if ($script:stats.ExecutionErr) { Write-Log ('Execution errors: ' + $script:stats.ExecutionErr) -ForegroundColor Red }
	}
	Write-Log ''
}
foreach ($file in $script:files) {
	$script:stats.ExecutionErr = 0
	$fileName = Add-LongPrefix $file.FullName
	$fileDir = Add-LongPrefix $file.DirectoryName
	$fileExt = $file.Extension
	$fileStats = [PSCustomObject]@{
		EntChecked = 0
		EntSkipped = 0
		DuplicateEntries = 0
		MissingEntries = 0
		MissingFiles = 0
		HashCalculated = 0
		HashNotCalculated = 0
		HashMismatches = 0
	}
	$skipStats = $false
	Write-Log ('Checking checksum file: ' + (Remove-LongPrefix $fileName))
	if (($script:opts.MissingEntries -or ($script:opts.VerifyHashes -eq [HashMode]::SearchPaths)) -and $script:auto) {
		$newFiles = [ordered]@{}
		$baseDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
		if ([System.IO.Directory]::Exists($baseDir)) {
			$script:paths = @($baseDir)
		} else {
			$script:paths = @($fileDir)
		}
		Write-Log ('Search path: ' + (Remove-LongPrefix $script:paths[0]))
		if ($script:opts.MissingEntries) { $newFiles = Get-NewFiles $script:paths }
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
				if ($algorithm -eq 'CRC32') {
					$ent = $match.Groups[1].Value
					$entHash = $match.Groups[2].Value
				} else {
					$entHash = $match.Groups[1].Value
					$ent = $match.Groups[2].Value
				}
			}
			if ($ent) {
				try {
					if ([System.IO.Path]::IsPathRooted($ent)) {
						$entPath = Get-LongPath $ent
					} else {
						$entPath = Get-LongPath ([System.IO.Path]::Combine($fileDir, $ent))
					}
					if (($algorithm -eq 'CRC32') -and $line.TrimStart().StartsWith(';', [System.StringComparison]::Ordinal) -and (-not (Test-FileExist $entPath))) {
						$ent = $null
					}
				} catch {
					Write-Err $_
					Write-Log ('Entry error: ' + $ent) -ForegroundColor Red
					$ent = $null
				}
			}
			if ($ent) {
				$fileStats.EntChecked++
				$entKey = $entPath
				if ($keys.ContainsKey($entKey)) {
					$fileStats.DuplicateEntries++
					if ($script:opts.DuplicateEntries) {
						Write-Log ('Duplicate entry: ' + $ent) -ForegroundColor Cyan
						continue
					} else {
						$entKey = '<DUP' + $fileStats.DuplicateEntries + '>'
					}
				} else {
					$keys[$entKey] = $null
				}
				$fileExist = Test-FileExist $entPath
				if ($fileExist) {
					$entLine = $line
					if ($script:opts.VerifyHashes -ne [HashMode]::No) {
						$verifyHash = $true
						if (($null -ne $hashFileTime) -and (-not (Test-FileTime $entPath $hashFileTime))) { $verifyHash = $false }
						if ($verifyHash -and ($script:opts.HashInclude.Count -gt 0) -and (-not (Test-FileMask $entPath $script:opts.HashInclude $true))) { $verifyHash = $false }
						if ($verifyHash -and ($script:opts.HashExclude.Count -gt 0) -and (-not (Test-FileMask $entPath $script:opts.HashExclude $false))) { $verifyHash = $false }
						if ($verifyHash -and ($script:opts.VerifyHashes -eq [HashMode]::SearchPaths) -and (-not (Test-FilePath $entPath $script:paths))) { $verifyHash = $false }
						if ($verifyHash) {
							$hashKey = '<' + $algorithm + '>' + $entPath
							$hash = $hashes[$hashKey]
							if ($null -eq $hash) {
								$hash = Get-HashValue $entPath $algorithm
								if ($null -ne $hash) { $hashes[$hashKey] = $hash }
							}
							if ($null -eq $hash) {
								Write-Log ('Failed to calculate hash: ' + $ent) -ForegroundColor Red
								$fileStats.HashNotCalculated++
							} else {
								if ($entHash -ne $hash) {
									Write-Log ('Hash mismatch: ' + $ent) -ForegroundColor Red
									$fileStats.HashMismatches++
									$entLine = Get-EntLine $ent $hash $algorithm
								} elseif ($script:opts.Verbose) {
									Write-Log ('Hash matched: ' + $ent) -ForegroundColor Green
								}
								$fileStats.HashCalculated++
							}
						}
					}
					$entries[$entKey] = $entLine
				} elseif (($null -ne $fileExist) -and $script:opts.MissingFiles) {
					Write-Log ('Missing file: ' + $ent) -ForegroundColor Magenta
					$fileStats.MissingFiles++
				} else {
					$entries[$entKey] = $line
				}
			} else {
				$fileStats.EntSkipped++
				$entries['<SKIP' + $fileStats.EntSkipped + '>'] = $line
			}
		}
		foreach ($entPath in $newFiles.Keys) {
			if ($entries.Contains($entPath)) { continue }
			if (($entPath -eq $fileName) -or ($entPath -eq $batFile)) { continue }
			if (($null -ne $entFileTime) -and (-not (Test-FileTime $entPath $entFileTime))) { continue }
			if (($script:opts.EntInclude.Count -gt 0) -and (-not (Test-FileMask $entPath $script:opts.EntInclude $true))) { continue }
			if (($script:opts.EntExclude.Count -gt 0) -and (-not (Test-FileMask $entPath $script:opts.EntExclude $false))) { continue }
			$baseDir = $fileDir.TrimEnd('\') + '\'
			if ((-not $script:opts.AbsPaths) -and $entPath.StartsWith($baseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
				$ent = $entPath.Substring($baseDir.Length).TrimStart('\')
			} else {
				$ent = Remove-LongPrefix $entPath
			}
			Write-Log ('Missing entry: ' + $ent) -ForegroundColor Yellow
			$fileStats.MissingEntries++
			$newEntries[$entPath] = $ent
		}
	} catch {
		Write-Err $_
		Write-Log 'Failed to check checksum file!' -ForegroundColor Red
		$script:stats.FilesNotChecked++
		$skipStats = $true
	}
	$listErr = $false
	$warnings = $false
	$entDeleted = 0
	if ($script:stats.ExecutionErr) {
		$script:stats.CheckErr += $script:stats.ExecutionErr
		Write-Log ('Execution errors: ' + $script:stats.ExecutionErr) -ForegroundColor Red
	}
	if ($skipStats) {
		Write-Log ''
		continue
	}
	if ($fileStats.EntChecked) {
		Write-Log ('Entries checked: ' + $fileStats.EntChecked)
		$script:stats.EntChecked += $fileStats.EntChecked
	} else {
		Write-Log 'Entries not found in checksum file!' -ForegroundColor Yellow
		$script:stats.FilesEmpty++
		$warnings = $true
	}
	if ($script:opts.MissingEntries -and (($script:auto -and ($newFiles.Count -eq 0)) -or (($script:files.Count -eq 1) -and $script:stats.SearchEmpty))) {
		Write-Log 'Files not found in search paths!' -ForegroundColor Yellow
		$warnings = $true
	}
	if ($fileStats.EntSkipped) {
		Write-Log ('Lines skipped: ' + $fileStats.EntSkipped)
		$script:stats.EntSkipped += $fileStats.EntSkipped
	}
	if ($script:opts.DuplicateEntries -and $fileStats.DuplicateEntries) {
		Write-Log ('Duplicate entries: ' + $fileStats.DuplicateEntries) -ForegroundColor Cyan
		$script:stats.DuplicateEntries += $fileStats.DuplicateEntries
		$entDeleted += $fileStats.DuplicateEntries
		$listErr = $true
	}
	if ($fileStats.MissingFiles) {
		Write-Log ('Missing files: ' + $fileStats.MissingFiles) -ForegroundColor Magenta
		$script:stats.MissingFiles += $fileStats.MissingFiles
		$entDeleted += $fileStats.MissingFiles
		$listErr = $true
	}
	if ($fileStats.MissingEntries) {
		Write-Log ('Missing entries: ' + $fileStats.MissingEntries) -ForegroundColor Yellow
		$script:stats.MissingEntries += $fileStats.MissingEntries
		$listErr = $true
	}
	if ($fileStats.HashCalculated) {
		Write-Log ('Hashes calculated: ' + $fileStats.HashCalculated)
		$script:stats.HashCalculated += $fileStats.HashCalculated
	}
	if ($fileStats.HashNotCalculated) {
		Write-Log ('Hashes not calculated: ' + $fileStats.HashNotCalculated) -ForegroundColor Red
		$script:stats.HashNotCalculated += $fileStats.HashNotCalculated
	}
	if ($fileStats.HashMismatches) {
		Write-Log ('Hash mismatches: ' + $fileStats.HashMismatches) -ForegroundColor Red
		$script:stats.HashMismatches += $fileStats.HashMismatches
		$listErr = $true
	}
	if ($listErr -and (-not ($script:opts.Safe -and ($script:stats.ExecutionErr -or $script:stats.GlobalErr)))) {
		$updObjects[$fileName] = [PSCustomObject]@{
			Algorithm = $algorithm
			Encoding = $encoding
			Entries = $entries
			NewEntries = $newEntries
			EntDeleted = $entDeleted
			EntUpdated = $fileStats.HashMismatches
			EntAdded = 0
			EntNotAdded = 0
		}
	}
	if ($script:stats.ExecutionErr -or $script:stats.GlobalErr) {
		Write-Log 'Checksum file checked with errors!' -ForegroundColor Red
		$script:stats.FilesCheckedErr++
	} else {
		if (-not ($listErr -or $warnings)) {
			Write-Log 'Checksum file checked successfully!' -ForegroundColor Green
		}
		$script:stats.FilesChecked++
	}
	Write-Log ''
}
Write-Log 'Check completed!'
$script:stats.CheckErr += $script:stats.GlobalErr
if ($script:files.Count -ne 1) {
	Write-Log ''
	$listErr = $false
	$warnings = $false
	if ($script:stats.CheckErr) { Write-Log ('Execution errors: ' + $script:stats.CheckErr) -ForegroundColor Red }
	if ($script:stats.FilesChecked) { Write-Log ('Checksum files checked: ' + $script:stats.FilesChecked) }
	if ($script:stats.FilesCheckedErr) { Write-Log ('Checksum files checked with errors: ' + $script:stats.FilesCheckedErr) -ForegroundColor Red }
	if ($script:stats.FilesNotChecked) { Write-Log ('Not checked checksum files: ' + $script:stats.FilesNotChecked) -ForegroundColor Red }
	if ($script:stats.EntChecked) { Write-Log ('Entries checked: ' + $script:stats.EntChecked) }
	if ($script:stats.FilesEmpty) {
		if ($script:stats.EntChecked) {
			Write-Log ('Entries not found in checksum file: ' + $script:stats.FilesEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Entries not found in checksum files!' -ForegroundColor Yellow
		}
		$warnings = $true
	}
	if ($script:stats.SearchEmpty) {
		if ($script:auto) {
			Write-Log ('Files not found in search paths: ' + $script:stats.SearchEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Files not found in search paths!' -ForegroundColor Yellow
		}
		$warnings = $true
	}
	if ($script:stats.EntSkipped) { Write-Log ('Lines skipped: ' + $script:stats.EntSkipped) }
	if ($script:stats.DuplicateEntries) {
		Write-Log ('Duplicate entries: ' + $script:stats.DuplicateEntries) -ForegroundColor Cyan
		$listErr = $true
	}
	if ($script:stats.MissingFiles) {
		Write-Log ('Missing files: ' + $script:stats.MissingFiles) -ForegroundColor Magenta
		$listErr = $true
	}
	if ($script:stats.MissingEntries) {
		Write-Log ('Missing entries: ' + $script:stats.MissingEntries) -ForegroundColor Yellow
		$listErr = $true
	}
	if ($script:stats.HashCalculated) { Write-Log ('Hashes calculated: ' + $script:stats.HashCalculated) }
	if ($script:stats.HashNotCalculated) { Write-Log ('Hashes not calculated: ' + $script:stats.HashNotCalculated) -ForegroundColor Red }
	if ($script:stats.HashMismatches) {
		Write-Log ('Hash mismatches: ' + $script:stats.HashMismatches) -ForegroundColor Red
		$listErr = $true
	}
	if ($script:stats.CheckErr -or $script:stats.GlobalErr) {
		Write-Log 'Check completed with errors!' -ForegroundColor Red
	} elseif (-not ($listErr -or $warnings)) {
		Write-Log 'Check completed successfully!' -ForegroundColor Green
	}
}
$finalPause = $true
if ($updObjects.Count -gt 0) {
	if ($script:opts.UpdateMsg) {
		Write-Host ''
		$ret = $true
		while ($ret) {
			if ($script:stats.CheckErr -or $script:stats.GlobalErr) {
				Write-Host 'Update' -ForegroundColor Red -NoNewline
			} else {
				Write-Host 'Update' -ForegroundColor Green -NoNewline
			}
			Write-Host ' checksum files? (Yes / ' -NoNewline
			Write-Host '[No]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$script:opts.Update = $false
					$ret = $false
					break
				}
				'^(y|yes)$' {
					$script:opts.Update = $true
					$ret = $false
					break
				}
				'^(n|no)$' {
					$script:opts.Update = $false
					$ret = $false
					break
				}
			}
		}
		$finalPause = $false
	}
	if ($script:opts.Update) {
		Write-Log ''
		Write-Log 'Update started' -NoHost
		Write-Log '' -NoHost
		foreach ($fileName in $updObjects.Keys) {
			$script:stats.ExecutionErr = 0
			$updObj = $updObjects[$fileName]
			$tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($fileName), 'Checksum_File_' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
			$bakIdx = 0
			$bakFile = $fileName + '.bak'
			$bakExist = $false
			$skipStats = $false
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
						if ($script:opts.Safe) { throw [CustomException]::new('Update aborted!') }
						$updObj.EntNotAdded++
					} else {
						$updObj.Entries[$entPath] = Get-EntLine $ent $hash $updObj.Algorithm
						if ($script:opts.Verbose) { Write-Log ('Hash calculated: ' + $ent) -ForegroundColor Green }
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
				$script:stats.FilesNotUpdated++
				$skipStats = $true
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
				$script:stats.FilesNotUpdated++
				$skipStats = $true
			} finally {
				if ([System.IO.File]::Exists($tempFile)) {
					try { [System.IO.File]::Delete($tempFile) } catch {}
				}
			}
			if ($script:stats.ExecutionErr) {
				$script:stats.UpdateErr += $script:stats.ExecutionErr
				Write-Log ('Execution errors: ' + $script:stats.ExecutionErr) -ForegroundColor Red
			}
			if ($skipStats) {
				Write-Log ''
				continue
			}
			if ($updObj.EntDeleted) {
				Write-Log ('Entries deleted: ' + $updObj.EntDeleted)
				$script:stats.EntDeleted += $updObj.EntDeleted
			}
			if ($updObj.EntUpdated) {
				Write-Log ('Entries updated: ' + $updObj.EntUpdated)
				$script:stats.EntUpdated += $updObj.EntUpdated
			}
			if ($updObj.EntAdded) {
				Write-Log ('Entries added: ' + $updObj.EntAdded)
				$script:stats.EntAdded += $updObj.EntAdded
			}
			if ($updObj.EntNotAdded) {
				Write-Log ('Entries not added: ' + $updObj.EntNotAdded) -ForegroundColor Red
				$script:stats.EntNotAdded += $updObj.EntNotAdded
			}
			if ($script:stats.ExecutionErr) {
				Write-Log 'Checksum file updated with errors!' -ForegroundColor Red
				$script:stats.FilesUpdatedErr++
			} else {
				Write-Log 'Checksum file updated successfully!' -ForegroundColor Green
				$script:stats.FilesUpdated++
			}
			Write-Log ''
		}
		Write-Log 'Update completed!'
		if ($updObjects.Count -ne 1) {
			Write-Log ''
			if ($script:stats.UpdateErr) { Write-Log ('Execution errors: ' + $script:stats.UpdateErr) -ForegroundColor Red }
			if ($script:stats.FilesUpdated) { Write-Log ('Checksum files updated: ' + $script:stats.FilesUpdated) }
			if ($script:stats.FilesUpdatedErr) { Write-Log ('Checksum files updated with errors: ' + $script:stats.FilesUpdatedErr) -ForegroundColor Red }
			if ($script:stats.FilesNotUpdated) { Write-Log ('Checksum files not updated: ' + $script:stats.FilesNotUpdated) -ForegroundColor Red }
			if ($script:stats.EntDeleted) { Write-Log ('Entries deleted: ' + $script:stats.EntDeleted) }
			if ($script:stats.EntUpdated) { Write-Log ('Entries updated: ' + $script:stats.EntUpdated) }
			if ($script:stats.EntAdded) { Write-Log ('Entries added: ' + $script:stats.EntAdded) }
			if ($script:stats.EntNotAdded) { Write-Log ('Entries not added: ' + $script:stats.EntNotAdded) -ForegroundColor Red }
			if ($script:stats.UpdateErr) {
				Write-Log 'Update completed with errors!' -ForegroundColor Red
			} else {
				Write-Log 'Update completed successfully!' -ForegroundColor Green
			}
		}
		$finalPause = $true
	}
}
if ($script:opts.LogMsg) {
	Write-Host ''
	$ret = $true
	while ($ret) {
		Write-Host 'Save check log? (Yes / ' -NoNewline
		Write-Host '[No]' -ForegroundColor Green -NoNewline
		$read = Read-Host ')'
		switch -Regex ($read.Trim()) {
			'^$' {
				$script:opts.Log = $false
				$ret = $false
				break
			}
			'^(y|yes)$' {
				$script:opts.Log = $true
				$ret = $false
				break
			}
			'^(n|no)$' {
				$script:opts.Log = $false
				$ret = $false
				break
			}
		}
	}
	$finalPause = $false
}
$logErr = $false
if ($script:opts.Log) {
	Write-Host ''
	$tempFile = [System.IO.Path]::Combine($batDir, 'Check_Log_' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
	$logIdx = 0
	$logName = 'Check_Log_' + $startTime.ToString('yyyy-MM-dd_HH-mm-ss')
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
if ($script:stats.CheckErr) { $exit = $exit -bor 4 }
if ($script:stats.UpdateErr) { $exit = $exit -bor 8 }
if ($script:stats.DuplicateEntries) { $exit = $exit -bor 16 }
if ($script:stats.MissingFiles) { $exit = $exit -bor 32 }
if ($script:stats.MissingEntries) { $exit = $exit -bor 64 }
if ($script:stats.HashMismatches) { $exit = $exit -bor 128 }
if ($script:stats.FilesEmpty) { $exit = $exit -bor 256 }
if ($script:stats.SearchEmpty) { $exit = $exit -bor 512 }
if ($logErr) { $exit = $exit -bor 1024 }
exit $exit
