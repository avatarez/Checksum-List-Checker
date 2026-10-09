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

enum VerifyMode {
	No
	All
	SearchPaths
}

enum FilterMode {
	MissingEntries
	Hashes
}

$script:options = [PSCustomObject]@{
	ShowMenu = $true
	DuplicateEntries = $true
	MissingFiles = $true
	MissingEntries = $true
	VerifyHashes = [VerifyMode]::No
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
	SysRes = $true
	Update = $false
	UpdateMsg = $true
	Log = $false
	LogMsg = $true
	Safe = $false
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
	FilesEmpty = 0
	SearchErr = 0
	SearchEmpty = 0
	CurrentSearchErr = 0
	CurrentSearchEmpty = 0
	EntriesChecked = 0
	LinesSkipped = 0
	DuplicateEntries = 0
	MissingEntries = 0
	MissingFiles = 0
	HashesCalculated = 0
	HashesNotCalculated = 0
	HashMismatches = 0
	EntriesDeleted = 0
	EntriesUpdated = 0
	EntriesAdded = 0
	EntriesNotAdded = 0
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
$script:checkAuto = $true
$script:logList = [System.Collections.Generic.List[string]]::new()
$script:ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage, [System.Text.EncoderExceptionFallback]::new(), [System.Text.DecoderExceptionFallback]::new())
$script:utf = [System.Text.UTF8Encoding]::new($false, $true)
$script:regexDupSep = [regex]::new('\\{2,}', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Show-Menu {
	$restart = $true
	while ($restart) {
		Clear-Host
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		if ($script:checkFiles.Count -eq 1) {
			Write-Host ('Файл контрольных сумм: ' + (Remove-LongPrefix $script:checkFiles[0].FullName))
		} elseif ($script:checkFiles.Count -gt 0) {
			Write-Host ('Файлов контрольных сумм: ' + $script:checkFiles.Count)
		} else {
			Write-Host 'Файлы контрольных сумм: Нет' -ForegroundColor Red
		}
		if ($script:checkAuto) {
			if ($script:options.NoAuto) {
				Write-Host 'Пути поиска: Нет'
			} else {
				Write-Host 'Пути поиска: Авто'
			}
		} elseif ($script:checkPaths.Count -eq 1) {
			Write-Host ('Путь поиска: ' + (Remove-LongPrefix $script:checkPaths[0]))
		} else {
			Write-Host ('Путей поиска: ' + $script:checkPaths.Count)
		}
		Write-Host ''
		if ($script:checkFiles.Count -gt 0) {
			Write-Host '1.  [Начать проверку]' -ForegroundColor Green
		} else {
			Write-Host '1.  [Начать проверку]' -ForegroundColor DarkGreen
		}
		Write-Host ''
		if ($script:options.DuplicateEntries) {
			Write-Host '2.  Проверять ' -NoNewline
			Write-Host 'дублирующиеся записи' -ForegroundColor Cyan -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '2.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'дублирующиеся записи' -ForegroundColor DarkCyan -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:options.MissingFiles) {
			Write-Host '3.  Проверять ' -NoNewline
			Write-Host 'отсутствующие файлы' -ForegroundColor Magenta -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '3.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'отсутствующие файлы' -ForegroundColor DarkMagenta -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:checkAuto -and $script:options.NoAuto) {
			Write-Host '4.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'отсутствующие записи' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Недоступно' -ForegroundColor DarkGray
		} elseif ($script:options.MissingEntries) {
			Write-Host '4.  Проверять ' -NoNewline
			Write-Host 'отсутствующие записи' -ForegroundColor Yellow -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '4.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'отсутствующие записи' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:options.VerifyHashes -eq [VerifyMode]::All) {
			Write-Host '5.  Проверять ' -NoNewline
			Write-Host 'хэши' -ForegroundColor Red -NoNewline
			Write-Host ' (медленно): Все'
		} elseif ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths) {
			Write-Host '5.  Проверять ' -NoNewline
			Write-Host 'хэши' -ForegroundColor Red -NoNewline
			Write-Host ' (медленно): По путям поиска'
		} else {
			Write-Host '5.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'хэши' -ForegroundColor DarkRed -NoNewline
			Write-Host ' (медленно): Нет' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:options.MissingEntries) {
			if ([string]::IsNullOrEmpty($script:options.EntMask)) {
				Write-Host '6.  Фильтр отсутствующих записей по маске: Нет' -ForegroundColor DarkGray
			} elseif ($script:options.EntMaskInclude) {
				Write-Host ('6.  Фильтр отсутствующих записей по маске (включить): ' + $script:options.EntMask)
			} else {
				Write-Host ('6.  Фильтр отсутствующих записей по маске (исключить): ' + $script:options.EntMask)
			}
		} else {
			Write-Host '6.  Фильтр отсутствующих записей по маске: Недоступно' -ForegroundColor DarkGray
		}
		if ($script:options.MissingEntries) {
			if ($script:options.EntTimeValue -gt 0) {
				Write-Host ('7.  Фильтр отсутствующих записей по времени изменения (' + (Get-TimeUnit $script:options.EntTimeUnit) + '): ' + $script:options.EntTimeValue)
			} else {
				Write-Host '7.  Фильтр отсутствующих записей по времени изменения: Нет' -ForegroundColor DarkGray
			}
		} else {
			Write-Host '7.  Фильтр отсутствующих записей по времени изменения: Недоступно' -ForegroundColor DarkGray
		}
		if ($script:options.VerifyHashes -ne [VerifyMode]::No) {
			if ([string]::IsNullOrEmpty($script:options.HashMask)) {
				Write-Host '8.  Фильтр хэшей по маске: Нет' -ForegroundColor DarkGray
			} elseif ($script:options.HashMaskInclude) {
				Write-Host ('8.  Фильтр хэшей по маске (включить): ' + $script:options.HashMask)
			} else {
				Write-Host ('8.  Фильтр хэшей по маске (исключить): ' + $script:options.HashMask)
			}
		} else {
			Write-Host '8.  Фильтр хэшей по маске: Недоступно' -ForegroundColor DarkGray
		}
		if ($script:options.VerifyHashes -ne [VerifyMode]::No) {
			if ($script:options.HashTimeValue -gt 0) {
				Write-Host ('9.  Фильтр хэшей по времени изменения (' + (Get-TimeUnit $script:options.HashTimeUnit) + '): ' + $script:options.HashTimeValue)
			} else {
				Write-Host '9.  Фильтр хэшей по времени изменения: Нет' -ForegroundColor DarkGray
			}
		} else {
			Write-Host '9.  Фильтр хэшей по времени изменения: Недоступно' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:options.HashVerbose) {
			Write-Host '10. Подробный режим проверки ' -NoNewline
			Write-Host 'хэшей' -ForegroundColor Green -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '10. Подробный режим проверки ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'хэшей' -ForegroundColor DarkGreen -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:options.MissingEntries) {
			if ($script:options.AbsPaths) {
				Write-Host '11. Режим путей отсутствующих записей: Абсолютные'
			} else {
				Write-Host '11. Режим путей отсутствующих записей: Относительные'
			}
		} else {
			Write-Host '11. Режим путей отсутствующих записей: Недоступно' -ForegroundColor DarkGray
		}
		if ($script:options.SysRes) {
			Write-Host '12. Способ разрешения путей: Системный'
		} else {
			Write-Host '12. Способ разрешения путей: Внутренний'
		}
		Write-Host ''
		Write-Host '13. Обзор файлов контрольных сумм и путей поиска'
		Write-Host ''
		Write-Host '0.  Выход'
		Write-Host ''
		$readValue = Read-Host 'Выберите пункт меню (0-13)'
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
				if (-not ($script:checkAuto -and $script:options.NoAuto)) { $script:options.MissingEntries = -not $script:options.MissingEntries }
				break
			}
			'5' {
				if ($script:options.VerifyHashes -eq [VerifyMode]::All) {
					if ($script:checkAuto -and $script:options.NoAuto) {
						$script:options.VerifyHashes = [VerifyMode]::No
					} else {
						$script:options.VerifyHashes = [VerifyMode]::SearchPaths
					}
				} elseif ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths) {
					$script:options.VerifyHashes = [VerifyMode]::No
				} else {
					$script:options.VerifyHashes = [VerifyMode]::All
				}
				break
			}
			'6' {
				if ($script:options.MissingEntries) { Show-NewMask ([FilterMode]::MissingEntries) }
				break
			}
			'7' {
				if ($script:options.MissingEntries) { Show-NewTime ([FilterMode]::MissingEntries) }
				break
			}
			'8' {
				if ($script:options.VerifyHashes -ne [VerifyMode]::No) { Show-NewMask ([FilterMode]::Hashes) }
				break
			}
			'9' {
				if ($script:options.VerifyHashes -ne [VerifyMode]::No) { Show-NewTime ([FilterMode]::Hashes) }
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
				$script:options.SysRes = -not $script:options.SysRes
				break
			}
			'13' {
				Show-Paths
				break
			}
			'0' {
				exit 0
			}
		}
	}
}

function Show-NewMask {
	param(
		[FilterMode]$menuMode
	)
	$menuMaskInclude = $true
	$menuMaskValue = $null
	try {
		Clear-Host
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		Write-Host '1. Включить'
		Write-Host '2. Исключить'
		Write-Host ''
		$readValue = Read-Host 'Выберите режим фильтра по маске (1-2)'
		switch ($readValue.Trim()) {
			'1' {
				Write-Host ''
				$menuMaskValue = Read-Host 'Включить маску'
				break
			}
			'2' {
				$menuMaskInclude = $false
				Write-Host ''
				$menuMaskValue = Read-Host 'Исключить маску'
				break
			}
			default { throw }
		}
		Test-MaskInput $menuMaskValue
	} catch {
		$menuMaskInclude = $true
		$menuMaskValue = $null
	}
	switch ($menuMode) {
		([FilterMode]::MissingEntries) {
			$script:options.EntMaskInclude = $menuMaskInclude
			$script:options.EntMask = $menuMaskValue
			break
		}
		([FilterMode]::Hashes) {
			$script:options.HashMaskInclude = $menuMaskInclude
			$script:options.HashMask = $menuMaskValue
			break
		}
	}
}

function Show-NewTime {
	param(
		[FilterMode]$menuMode
	)
	$menuTimeUnit = $null
	$menuTimeValue = 0
	try {
		Clear-Host
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		Write-Host '1. Минуты'
		Write-Host '2. Часы'
		Write-Host '3. Дни'
		Write-Host '4. Месяцы'
		Write-Host '5. Годы'
		Write-Host ''
		$readValue = Read-Host 'Выберите единицу измерения времени (1-5)'
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
		$timeValue = Read-Host ('Время с момента последней записи файла (' + (Get-TimeUnit $menuTimeUnit) + ')')
		$menuTimeValue = [int]$timeValue
		Test-TimeInput $menuTimeUnit $menuTimeValue
	} catch {
		$menuTimeUnit = $null
		$menuTimeValue = 0
	}
	switch ($menuMode) {
		([FilterMode]::MissingEntries) {
			$script:options.EntTimeUnit = $menuTimeUnit
			$script:options.EntTimeValue = $menuTimeValue
			break
		}
		([FilterMode]::Hashes) {
			$script:options.HashTimeUnit = $menuTimeUnit
			$script:options.HashTimeValue = $menuTimeValue
			break
		}
	}
}

function Show-Paths {
	$restart = $true
	while ($restart) {
		$restart = $false
		Clear-Host
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		if ($script:checkFiles.Count -eq 0) {
			Show-NewPaths
			if ($script:checkFiles.Count -eq 0) {
				return
			} else {
				$restart = $true
				continue
			}
		}
		if ($script:checkAuto -and (-not $script:options.NoAuto)) {
			foreach ($file in $script:checkFiles) {
				Write-Host ('Файл контрольных сумм: ' + (Remove-LongPrefix $file.FullName))
				$fileDir = $file.DirectoryName
				$fileBaseNameDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
				if ([System.IO.Directory]::Exists($fileBaseNameDir)) {
					Write-Host ('Путь поиска: ' + (Remove-LongPrefix $fileBaseNameDir))
				} else {
					Write-Host ('Путь поиска: ' + (Remove-LongPrefix $fileDir))
				}
				Write-Host ''
			}
		} else {
			if ($script:checkFiles.Count -eq 1) {
				Write-Host ('Файл контрольных сумм: ' + (Remove-LongPrefix $script:checkFiles[0].FullName))
			} else {
				Write-Host 'Файлы контрольных сумм:'
				foreach ($file in $script:checkFiles) {
					Write-Host (Remove-LongPrefix $file.FullName)
				}
			}
			Write-Host ''
			if ($script:checkAuto -and $script:options.NoAuto) {
				Write-Host 'Пути поиска: Нет'
			} else {
				if ($script:checkPaths.Count -eq 1) {
					Write-Host ('Путь поиска: ' + (Remove-LongPrefix $script:checkPaths[0]))
				} else {
					Write-Host 'Пути поиска:'
					foreach ($path in $script:checkPaths) {
						Write-Host (Remove-LongPrefix $path)
					}
				}
			}
			Write-Host ''
		}
		$msg = $true
		while ($msg) {
			Write-Host 'Задать новые файлы и пути? (Да / ' -NoNewline
			Write-Host '[Нет]' -ForegroundColor Green -NoNewline
			$readValue = Read-Host ')'
			switch -Regex ($readValue.Trim()) {
				'^$' {
					$msg = $false
					break
				}
				'^(y|yes|д|да)$' {
					Write-Host ''
					Show-NewPaths
					if ($script:checkFiles.Count -eq 0) { return }
					$restart = $true
					$msg = $false
					break
				}
				'^(n|no|н|нет)$' {
					$msg = $false
					break
				}
			}
		}
	}
}

function Show-NewPaths {
	$readValue = Read-Host 'Файлы контрольных сумм'
	if (-not [string]::IsNullOrEmpty($readValue)) { Parse-Args $readValue -Files }
	Write-Host ''
	$readValue = Read-Host 'Пути поиска'
	if ([string]::IsNullOrEmpty($readValue)) {
		if (-not $script:checkAuto) {
			$msg = $true
			while ($msg) {
				Write-Host ''
				Write-Host 'Очистить пути поиска? (Да / ' -NoNewline
				Write-Host '[Нет]' -ForegroundColor Green -NoNewline
				$readValue = Read-Host ')'
				switch -Regex ($readValue.Trim()) {
					'^$' {
						$msg = $false
						break
					}
					'^(y|yes|д|да)$' {
						$script:checkPaths = @()
						$script:checkAuto = $true
						$msg = $false
						break
					}
					'^(n|no|н|нет)$' {
						$msg = $false
						break
					}
				}
			}
		}
	} else {
		Parse-Args $readValue -Paths
		$script:checkAuto = $script:checkPaths.Count -eq 0
	}
	if ($script:checkAuto -and $script:options.NoAuto) {
		$script:options.MissingEntries = $false
		if ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths) { $script:options.VerifyHashes = [VerifyMode]::No }
	}
}

function Parse-Args {
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
		if (-not ($pathSep -or $Files)) {
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
								$script:options.VerifyHashes = [VerifyMode]::All
								break
							}
							'^(-p|--verify-search-paths-hashes)$' {
								$script:options.VerifyHashes = [VerifyMode]::SearchPaths
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
								$script:options.SysRes = $false
								break
							}
							'^(-l|--save-log)$' {
								$script:options.LogMsg = $false
								$script:options.Log = $true
								break
							}
							'^(-s|--safe)$' {
								$script:options.Safe = $true
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
							'^--missing-entries-include=$' {
								Test-MaskInput $argValue
								$script:options.EntMask = $argValue
								$script:options.EntMaskInclude = $true
								$script:options.MissingEntries = $true
								break
							}
							'^--missing-entries-exclude=$' {
								Test-MaskInput $argValue
								$script:options.EntMask = $argValue
								$script:options.EntMaskInclude = $false
								$script:options.MissingEntries = $true
								break
							}
							'^--missing-entries-time-minutes=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Minutes) $intValue
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Minutes
								$script:options.MissingEntries = $true
								break
							}
							'^--missing-entries-time-hours=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Hours) $intValue
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Hours
								$script:options.MissingEntries = $true
								break
							}
							'^--missing-entries-time-days=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Days) $intValue
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Days
								$script:options.MissingEntries = $true
								break
							}
							'^--missing-entries-time-months=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Months) $intValue
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Months
								$script:options.MissingEntries = $true
								break
							}
							'^--missing-entries-time-years=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Years) $intValue
								$script:options.EntTimeValue = $intValue
								$script:options.EntTimeUnit = [TimeUnit]::Years
								$script:options.MissingEntries = $true
								break
							}
							'^--hashes-include=$' {
								Test-MaskInput $argValue
								$script:options.HashMask = $argValue
								$script:options.HashMaskInclude = $true
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							'^--hashes-exclude=$' {
								Test-MaskInput $argValue
								$script:options.HashMask = $argValue
								$script:options.HashMaskInclude = $false
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							'^--hashes-time-minutes=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Minutes) $intValue
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Minutes
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							'^--hashes-time-hours=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Hours) $intValue
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Hours
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							'^--hashes-time-days=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Days) $intValue
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Days
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							'^--hashes-time-months=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Months) $intValue
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Months
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							'^--hashes-time-years=$' {
								$intValue = [int]$argValue
								Test-TimeInput ([TimeUnit]::Years) $intValue
								$script:options.HashTimeValue = $intValue
								$script:options.HashTimeUnit = [TimeUnit]::Years
								if ($script:options.VerifyHashes -eq [VerifyMode]::No) { $script:options.VerifyHashes = [VerifyMode]::All }
								break
							}
							default { throw }
						}
					}
				} catch {
					Invoke-ClearHost
					Write-Host 'Ошибка синтаксиса!' -ForegroundColor Red
					Write-Host ('Недопустимый параметр: ' + $argRaw) -ForegroundColor Red
					Invoke-Pause
					exit 2
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
	if ($script:options.SysRes) {
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
	$script:stats.CurrentSearchEmpty = 0
	Get-ChildItem -LiteralPath $Paths -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +searchErrors | ForEach-Object { $newFiles[(Add-LongPrefix $_.FullName)] = $null }
	foreach ($err in $searchErrors) {
		Write-Log ('Ошибка поиска: ' + $err.Exception.Message) -ForegroundColor Red
		$script:stats.CurrentSearchErr++
	}
	$script:stats.SearchErr += $script:stats.CurrentSearchErr
	if ($newFiles.Count -gt 0) {
		Write-Log ('Найдено файлов: ' + $newFiles.Count)
	} else {
		Write-Log 'Файлы не найдены!'
		$script:stats.CurrentSearchEmpty++
	}
	$script:stats.SearchEmpty += $script:stats.CurrentSearchEmpty
	return $newFiles
}

function Get-TimeUnit {
	param(
		[TimeUnit]$Unit
	)
	switch ($Unit) {
		([TimeUnit]::Minutes) { return 'минуты' }
		([TimeUnit]::Hours) { return 'часы' }
		([TimeUnit]::Days) { return 'дни' }
		([TimeUnit]::Months) { return 'месяцы' }
		([TimeUnit]::Years) { return 'годы' }
	}
}

function Get-TimeLimit {
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

function Test-FileTime {
	param(
		[string]$Path,
		[DateTime]$TimeLimit
	)
	try {
		return ([System.IO.File]::GetLastWriteTime($Path) -ge $TimeLimit) -or ([System.IO.File]::GetCreationTime($Path) -ge $TimeLimit)
	} catch {
		return $false
	}
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

function Test-TimeInput {
	param(
		[TimeUnit]$Unit,
		[int]$Value
	)
	if ($Value -le 0) { throw }
	if ($null -eq (Get-TimeLimit $Unit $Value (Get-Date))) { throw }
}

function Test-MaskInput {
	param(
		[string]$Value
	)
	$masks = @($Value -split '\|' | Where-Object { $_ -ne '' })
	if ($masks.Count -eq 0) { throw }
	foreach ($mask in $masks) { [void]('' -like $mask) }
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
	if ([string]::IsNullOrEmpty($Text)) {
		$script:logList.Add('')
	} else {
		if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-Date }
		$script:logList.Add('[' + $Now.ToString('yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Text)
	}
}

function Invoke-ClearHost {
	if (-not $script:options.Quiet) { Clear-Host }
}

function Invoke-Pause {
	if (-not $script:options.Quiet) {
		Write-Host ''
		pause
	}
}

Parse-Args $env:BATARGS
$script:checkAuto = $script:checkPaths.Count -eq 0
$batFile = Get-LongPath $env:BATFILE
$batDir = Get-LongPath $env:BATDIR
if (($script:checkFiles.Count -eq 0) -and (-not $script:options.NoAuto)) {
	$script:checkFiles = @(Get-ChildItem -LiteralPath $batDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $script:fileAlgorithms.ContainsKey($_.Extension) })
}
if ($script:checkAuto -and $script:options.NoAuto) {
	$script:options.MissingEntries = $false
	if ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths) { $script:options.VerifyHashes = [VerifyMode]::No }
}
if ($script:options.ShowMenu) { Show-Menu }
$startTime = Get-Date
Invoke-ClearHost
Write-Log 'Начало проверки' -Now $startTime -NoHost
Write-Log '' -NoHost
if ($script:checkFiles.Count -eq 0) {
	Write-Host 'Файлы контрольных сумм не найдены!' -ForegroundColor Red
	Write-Host 'Поддерживаемые форматы файлов: .sfv, .md5, .sha1, .sha256, .sha384, .sha512' -ForegroundColor Red
	Invoke-Pause
	exit 1
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
$hashMask = @()
if (-not [string]::IsNullOrEmpty($script:options.HashMask)) {
	$hashMask = @($script:options.HashMask -split '\|' | Where-Object { $_ -ne '' })
}
$hashTimeLimit = $null
if ($script:options.HashTimeValue -gt 0) {
	$hashTimeLimit = Get-TimeLimit $script:options.HashTimeUnit $script:options.HashTimeValue $startTime
}
$entMask = @()
if (-not [string]::IsNullOrEmpty($script:options.EntMask)) {
	$entMask = @($script:options.EntMask -split '\|' | Where-Object { $_ -ne '' })
}
$entTimeLimit = $null
if ($script:options.EntTimeValue -gt 0) {
	$entTimeLimit = Get-TimeLimit $script:options.EntTimeUnit $script:options.EntTimeValue $startTime
}
$hashes = @{}
$updateObjects = [ordered]@{}
$newFiles = [ordered]@{}
if (($script:options.MissingEntries -or ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths)) -and (-not $script:checkAuto)) {
	if ($script:checkPaths.Count -eq 1) {
		Write-Log ('Путь поиска: ' + (Remove-LongPrefix $script:checkPaths[0]))
	} else {
		Write-Log 'Пути поиска:'
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
	Write-Log ('Проверка файла: ' + (Remove-LongPrefix $fileName))
	if (($script:options.MissingEntries -or ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths)) -and $script:checkAuto) {
		$newFiles = [ordered]@{}
		$fileBaseNameDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
		if ([System.IO.Directory]::Exists($fileBaseNameDir)) {
			$script:checkPaths = @($fileBaseNameDir)
		} else {
			$script:checkPaths = @($fileDir)
		}
		Write-Log ('Путь поиска: ' + (Remove-LongPrefix $script:checkPaths[0]))
		if ($script:options.MissingEntries) { $newFiles = Get-NewFiles $script:checkPaths }
	}
	$algorithm = $script:fileAlgorithms[$fileExtension]
	$pattern = $regexPatterns[$fileExtension]
	$entries = [ordered]@{}
	$keys = @{}
	try {
		$encoding = Get-Encoding $fileName
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
						Write-Log ('Дублируется запись: ' + $ent) -ForegroundColor Cyan
						continue
					} else {
						$entKey = '<DUP' + $fileStats.DuplicateEntries + '>'
					}
				} else {
					$keys[$entKey] = $null
				}
				if ([System.IO.File]::Exists($entPath)) {
					$entLine = $line
					if ($script:options.VerifyHashes -ne [VerifyMode]::No) {
						$verifyHash = $true
						if (($null -ne $hashTimeLimit) -and (-not (Test-FileTime $entPath $hashTimeLimit))) { $verifyHash = $false }
						if ($verifyHash -and ($hashMask.Count -gt 0) -and (-not (Test-FileMask $entPath $hashMask $script:options.HashMaskInclude))) { $verifyHash = $false }
						if ($verifyHash -and ($script:options.VerifyHashes -eq [VerifyMode]::SearchPaths) -and (-not (Test-FilePath $entPath $script:checkPaths))) { $verifyHash = $false }
						if ($verifyHash) {
							$hashKey = '<' + $algorithm + '>' + $entPath
							$hash = $hashes[$hashKey]
							if ($null -eq $hash) {
								$hash = Get-HashValue $entPath $algorithm
								if ($null -ne $hash) { $hashes[$hashKey] = $hash }
							}
							if ($null -eq $hash) {
								Write-Log ('Не удалось вычислить хэш: ' + $ent) -ForegroundColor Red
								$fileStats.HashesNotCalculated++
							} else {
								if ($entHash -ine $hash) {
									Write-Log ('Хэш не совпал: ' + $ent) -ForegroundColor Red
									$fileStats.HashMismatches++
									$entLine = Get-EntLine $ent $hash $algorithm
								} elseif ($script:options.HashVerbose) {
									Write-Log ('Хэш совпал: ' + $ent) -ForegroundColor Green
								}
								$fileStats.HashesCalculated++
							}
						}
					}
					$entries[$entKey] = $entLine
				} elseif ($script:options.MissingFiles) {
					Write-Log ('Отсутствует файл: ' + $ent) -ForegroundColor Magenta
					$fileStats.MissingFiles++
				} else {
					$entries[$entKey] = $line
				}
			} else {
				$fileStats.LinesSkipped++
				$entries['<SKIP' + $fileStats.LinesSkipped + '>'] = $line
			}
		}
	} catch {
		Write-Log 'Не удалось проверить файл контрольных сумм!' -ForegroundColor Red
		Write-Log ''
		$script:stats.FilesNotChecked++
		continue
	}
	$newEntries = [ordered]@{}
	foreach ($entPath in $newFiles.Keys) {
		if ($entries.Contains($entPath)) { continue }
		if (($entPath -ieq $fileName) -or ($entPath -ieq $batFile)) { continue }
		if (($null -ne $entTimeLimit) -and (-not (Test-FileTime $entPath $entTimeLimit))) { continue }
		if (($entMask.Count -gt 0) -and (-not (Test-FileMask $entPath $entMask $script:options.EntMaskInclude))) { continue }
		$baseDir = $fileDir.TrimEnd('\') + '\'
		if ((-not $script:options.AbsPaths) -and $entPath.StartsWith($baseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
			$ent = $entPath.Substring($baseDir.Length).TrimStart('\')
		} else {
			$ent = Remove-LongPrefix $entPath
		}
		Write-Log ('Отсутствует запись: ' + $ent) -ForegroundColor Yellow
		$fileStats.MissingEntries++
		$newEntries[$entPath] = $ent
	}
	$checkWarnings = $false
	$checkErrors = $false
	$sysErrors = $false
	$entriesDeleted = 0
	if ($fileStats.EntriesChecked) {
		Write-Log ('Проверено записей в файле контрольных сумм: ' + $fileStats.EntriesChecked)
		$script:stats.EntriesChecked += $fileStats.EntriesChecked
	} else {
		Write-Log 'Записи в файле контрольных сумм не найдены!' -ForegroundColor Yellow
		$script:stats.FilesEmpty++
		$checkWarnings = $true
	}
	if ($script:checkAuto) {
		if ($script:stats.CurrentSearchErr) {
			Write-Log ('Ошибок поиска: ' + $script:stats.CurrentSearchErr) -ForegroundColor Red
			$sysErrors = $true
		}
		if ($script:stats.CurrentSearchEmpty) {
			Write-Log 'Файлы по путям поиска не найдены!' -ForegroundColor Yellow
			$checkWarnings = $true
		}
	} else {
		if ($script:stats.SearchErr) {
			if ($script:checkFiles.Count -eq 1) { Write-Log ('Ошибок поиска: ' + $script:stats.SearchErr) -ForegroundColor Red }
			$sysErrors = $true
		}
		if ($script:stats.SearchEmpty) {
			if ($script:checkFiles.Count -eq 1) { Write-Log 'Файлы по путям поиска не найдены!' -ForegroundColor Yellow }
			$checkWarnings = $true
		}
	}
	if ($fileStats.LinesSkipped) {
		Write-Log ('Пропущено строк: ' + $fileStats.LinesSkipped)
		$script:stats.LinesSkipped += $fileStats.LinesSkipped
	}
	if ($script:options.DuplicateEntries -and $fileStats.DuplicateEntries) {
		Write-Log ('Дублирующихся записей: ' + $fileStats.DuplicateEntries) -ForegroundColor Cyan
		$script:stats.DuplicateEntries += $fileStats.DuplicateEntries
		$entriesDeleted += $fileStats.DuplicateEntries
		$checkErrors = $true
	}
	if ($fileStats.MissingFiles) {
		Write-Log ('Отсутствующих файлов: ' + $fileStats.MissingFiles) -ForegroundColor Magenta
		$script:stats.MissingFiles += $fileStats.MissingFiles
		$entriesDeleted += $fileStats.MissingFiles
		$checkErrors = $true
	}
	if ($fileStats.MissingEntries) {
		Write-Log ('Отсутствующих записей: ' + $fileStats.MissingEntries) -ForegroundColor Yellow
		$script:stats.MissingEntries += $fileStats.MissingEntries
		$checkErrors = $true
	}
	if ($fileStats.HashesCalculated) {
		Write-Log ('Вычислено хэшей: ' + $fileStats.HashesCalculated)
		$script:stats.HashesCalculated += $fileStats.HashesCalculated
	}
	if ($fileStats.HashesNotCalculated) {
		Write-Log ('Не вычислено хэшей: ' + $fileStats.HashesNotCalculated) -ForegroundColor Red
		$script:stats.HashesNotCalculated += $fileStats.HashesNotCalculated
		$sysErrors = $true
	}
	if ($fileStats.HashMismatches) {
		Write-Log ('Не совпало хэшей: ' + $fileStats.HashMismatches) -ForegroundColor Red
		$script:stats.HashMismatches += $fileStats.HashMismatches
		$checkErrors = $true
	}
	if ($checkErrors -and (-not ($sysErrors -and $script:options.Safe))) {
		$updateObjects[$fileName] = [PSCustomObject]@{
			Algorithm = $algorithm
			Encoding = $encoding
			Entries = $entries
			NewEntries = $newEntries
			EntriesDeleted = $entriesDeleted
			EntriesUpdated = $fileStats.HashMismatches
			EntriesAdded = 0
			EntriesNotAdded = 0
		}
	}
	if ($sysErrors) {
		Write-Log 'Проверка файла выполнена с ошибками!' -ForegroundColor Red
		$script:stats.FilesCheckedErr++
	} else {
		if (-not ($checkErrors -or $checkWarnings)) {
			Write-Log 'Проверка файла выполнена успешно!' -ForegroundColor Green
		}
		$script:stats.FilesChecked++
	}
	Write-Log ''
}
Write-Log 'Проверка завершена!'
if ($script:checkFiles.Count -ne 1) {
	Write-Log ''
	$checkWarnings = $false
	$checkErrors = $false
	$sysErrors = $false
	if ($script:stats.FilesChecked) { Write-Log ('Проверено файлов контрольных сумм: ' + $script:stats.FilesChecked) }
	if ($script:stats.FilesCheckedErr) {
		Write-Log ('Проверено файлов контрольных сумм с ошибками: ' + $script:stats.FilesCheckedErr) -ForegroundColor Red
		$sysErrors = $true
	}
	if ($script:stats.FilesNotChecked) {
		Write-Log ('Не проверено файлов контрольных сумм: ' + $script:stats.FilesNotChecked) -ForegroundColor Red
		$sysErrors = $true
	}
	if ($script:stats.EntriesChecked) {
		Write-Log ('Проверено записей в файлах контрольных сумм: ' + $script:stats.EntriesChecked)
		if ($script:stats.FilesEmpty) {
			Write-Log ('Записи в файле контрольных сумм не найдены: ' + $script:stats.FilesEmpty) -ForegroundColor Yellow
			$checkWarnings = $true
		}
	} elseif ($script:stats.FilesEmpty) {
		Write-Log 'Записи в файлах контрольных сумм не найдены!' -ForegroundColor Yellow
		$checkWarnings = $true
	}
	if ($script:stats.SearchErr) {
		Write-Log ('Ошибок поиска: ' + $script:stats.SearchErr) -ForegroundColor Red
		$sysErrors = $true
	}
	if ($script:stats.SearchEmpty) {
		if ($script:checkAuto) {
			Write-Log ('Файлы по путям поиска не найдены: ' + $script:stats.SearchEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Файлы по путям поиска не найдены!' -ForegroundColor Yellow
		}
		$checkWarnings = $true
	}
	if ($script:stats.LinesSkipped) { Write-Log ('Пропущено строк: ' + $script:stats.LinesSkipped) }
	if ($script:stats.DuplicateEntries) {
		Write-Log ('Дублирующихся записей: ' + $script:stats.DuplicateEntries) -ForegroundColor Cyan
		$checkErrors = $true
	}
	if ($script:stats.MissingFiles) {
		Write-Log ('Отсутствующих файлов: ' + $script:stats.MissingFiles) -ForegroundColor Magenta
		$checkErrors = $true
	}
	if ($script:stats.MissingEntries) {
		Write-Log ('Отсутствующих записей: ' + $script:stats.MissingEntries) -ForegroundColor Yellow
		$checkErrors = $true
	}
	if ($script:stats.HashesCalculated) { Write-Log ('Вычислено хэшей: ' + $script:stats.HashesCalculated) }
	if ($script:stats.HashesNotCalculated) {
		Write-Log ('Не вычислено хэшей: ' + $script:stats.HashesNotCalculated) -ForegroundColor Red
		$sysErrors = $true
	}
	if ($script:stats.HashMismatches) {
		Write-Log ('Не совпало хэшей: ' + $script:stats.HashMismatches) -ForegroundColor Red
		$checkErrors = $true
	}
	if ($sysErrors) {
		Write-Log 'Проверка выполнена с ошибками!' -ForegroundColor Red
	} elseif (-not ($checkErrors -or $checkWarnings)) {
		Write-Log 'Проверка выполнена успешно!' -ForegroundColor Green
	}
}
$finalPause = $true
if ($updateObjects.Count -gt 0) {
	if ($script:options.UpdateMsg) {
		Write-Host ''
		$msg = $true
		while ($msg) {
			if ($sysErrors) {
				Write-Host 'Обновить' -ForegroundColor Red -NoNewline
			} else {
				Write-Host 'Обновить' -ForegroundColor Green -NoNewline
			}
			Write-Host ' файлы контрольных сумм? (Да / ' -NoNewline
			Write-Host '[Нет]' -ForegroundColor Green -NoNewline
			$readValue = Read-Host ')'
			switch -Regex ($readValue.Trim()) {
				'^$' {
					$script:options.Update = $false
					$msg = $false
					break
				}
				'^(y|yes|д|да)$' {
					$script:options.Update = $true
					$msg = $false
					break
				}
				'^(n|no|н|нет)$' {
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
		Write-Log 'Начало обновления' -NoHost
		Write-Log '' -NoHost
		foreach ($fileName in $updateObjects.Keys) {
			Write-Log ('Обновление файла: ' + (Remove-LongPrefix $fileName))
			$updObj = $updateObjects[$fileName]
			$tempFile = $fileName + '_' + [System.Guid]::NewGuid().ToString('N') + '.tmp'
			$bakIdx = 0
			$bakFile = $fileName + '.bak'
			$bakExist = $false
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
						Write-Log ('Не удалось вычислить хэш: ' + $ent) -ForegroundColor Red
						if ($script:options.Safe) { throw }
						$updObj.EntriesNotAdded++
					} else {
						$updObj.Entries[$entPath] = Get-EntLine $ent $hash $updObj.Algorithm
						if ($script:options.HashVerbose) { Write-Log ('Вычислен хэш: ' + $ent) -ForegroundColor Green }
						$updObj.EntriesAdded++
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
				Write-Log ('Создана резервная копия: ' + (Remove-LongPrefix $bakFile))
				[System.IO.File]::Move($tempFile, $fileName)
			} catch {
				Write-Log 'Не удалось обновить файл!' -ForegroundColor Red
				$script:stats.FilesNotUpdated++
				if ($bakExist -and (-not [System.IO.File]::Exists($fileName)) -and [System.IO.File]::Exists($bakFile)) {
					try {
						[System.IO.File]::Move($bakFile, $fileName)
						Write-Log 'Файл восстановлен из резервной копии!' -ForegroundColor Red
					} catch {
						Write-Log 'Файл не восстановлен из резервной копии!' -ForegroundColor Red
					}
				}
				Write-Log ''
				continue
			} finally {
				if ([System.IO.File]::Exists($tempFile)) {
					try { [System.IO.File]::Delete($tempFile) } catch {}
				}
			}
			$sysErrors = $false
			if ($updObj.EntriesDeleted) {
				Write-Log ('Удалено записей: ' + $updObj.EntriesDeleted)
				$script:stats.EntriesDeleted += $updObj.EntriesDeleted
			}
			if ($updObj.EntriesUpdated) {
				Write-Log ('Обновлено записей: ' + $updObj.EntriesUpdated)
				$script:stats.EntriesUpdated += $updObj.EntriesUpdated
			}
			if ($updObj.EntriesAdded) {
				Write-Log ('Добавлено записей: ' + $updObj.EntriesAdded)
				$script:stats.EntriesAdded += $updObj.EntriesAdded
			}
			if ($updObj.EntriesNotAdded) {
				Write-Log ('Не добавлено записей: ' + $updObj.EntriesNotAdded) -ForegroundColor Red
				$script:stats.EntriesNotAdded += $updObj.EntriesNotAdded
				$sysErrors = $true
			}
			if ($sysErrors) {
				Write-Log 'Обновление файла выполнено с ошибками!' -ForegroundColor Red
				$script:stats.FilesUpdatedErr++
			} else {
				Write-Log 'Обновление файла выполнено успешно!' -ForegroundColor Green
				$script:stats.FilesUpdated++
			}
			Write-Log ''
		}
		Write-Log 'Обновление завершено!'
		if ($updateObjects.Count -ne 1) {
			Write-Log ''
			$sysErrors = $false
			if ($script:stats.FilesUpdated) { Write-Log ('Обновлено файлов контрольных сумм: ' + $script:stats.FilesUpdated) }
			if ($script:stats.FilesUpdatedErr) {
				Write-Log ('Обновлено файлов контрольных сумм с ошибками: ' + $script:stats.FilesUpdatedErr) -ForegroundColor Red
				$sysErrors = $true
			}
			if ($script:stats.FilesNotUpdated) {
				Write-Log ('Не обновлено файлов контрольных сумм: ' + $script:stats.FilesNotUpdated) -ForegroundColor Red
				$sysErrors = $true
			}
			if ($script:stats.EntriesDeleted) { Write-Log ('Удалено записей: ' + $script:stats.EntriesDeleted) }
			if ($script:stats.EntriesUpdated) { Write-Log ('Обновлено записей: ' + $script:stats.EntriesUpdated) }
			if ($script:stats.EntriesAdded) { Write-Log ('Добавлено записей: ' + $script:stats.EntriesAdded) }
			if ($script:stats.EntriesNotAdded) {
				Write-Log ('Не добавлено записей: ' + $script:stats.EntriesNotAdded) -ForegroundColor Red
				$sysErrors = $true
			}
			if ($sysErrors) {
				Write-Log 'Обновление выполнено с ошибками!' -ForegroundColor Red
			} else {
				Write-Log 'Обновление выполнено успешно!' -ForegroundColor Green
			}
		}
		$finalPause = $true
	}
}
if ($script:options.LogMsg) {
	Write-Host ''
	$msg = $true
	while ($msg) {
		Write-Host 'Сохранить журнал проверки? (Да / ' -NoNewline
		Write-Host '[Нет]' -ForegroundColor Green -NoNewline
		$readValue = Read-Host ')'
		switch -Regex ($readValue.Trim()) {
			'^$' {
				$script:options.Log = $false
				$msg = $false
				break
			}
			'^(y|yes|д|да)$' {
				$script:options.Log = $true
				$msg = $false
				break
			}
			'^(n|no|н|нет)$' {
				$script:options.Log = $false
				$msg = $false
				break
			}
		}
	}
	$finalPause = $false
}
$logError = $false
if ($script:options.Log) {
	Write-Host ''
	$logName = 'ChecksumListChecker_' + $startTime.ToString('yyyy-MM-dd_HH-mm-ss')
	$tempFile = [System.IO.Path]::Combine($batDir, ($logName + '_' + [System.Guid]::NewGuid().ToString('N') + '.tmp'))
	$logIdx = 0
	$logFile = [System.IO.Path]::Combine($batDir, $logName + '.txt')
	try {
		[System.IO.File]::WriteAllLines($tempFile, $script:logList, $script:utf)
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
		Write-Host ('Журнал проверки сохранён в файл: ' + (Remove-LongPrefix $logFile))
	} catch {
		Write-Host 'Не удалось сохранить журнал проверки!' -ForegroundColor Red
		$logError = $true
	} finally {
		if ([System.IO.File]::Exists($tempFile)) {
			try { [System.IO.File]::Delete($tempFile) } catch {}
		}
	}
	$finalPause = $true
}
if ($finalPause) { Invoke-Pause }

$exit = 0
if ($script:stats.FilesNotChecked) { $exit = $exit -bor 4 }
if ($script:stats.FilesNotUpdated) { $exit = $exit -bor 8 }
if ($script:stats.HashesNotCalculated) { $exit = $exit -bor 16 }
if ($script:stats.EntriesNotAdded) { $exit = $exit -bor 32 }
if ($script:stats.SearchErr) { $exit = $exit -bor 64 }
if ($script:stats.DuplicateEntries) { $exit = $exit -bor 128 }
if ($script:stats.MissingFiles) { $exit = $exit -bor 256 }
if ($script:stats.MissingEntries) { $exit = $exit -bor 512 }
if ($script:stats.HashMismatches) { $exit = $exit -bor 1024 }
if ($script:stats.FilesEmpty) { $exit = $exit -bor 2048 }
if ($script:stats.SearchEmpty) { $exit = $exit -bor 4096 }
if ($logError) { $exit = $exit -bor 8192 }
exit $exit
