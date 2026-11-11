<# :batBegin
@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
set CMDARGS=%*
set "CURDIR=%CD%"
set "BATFILE=%~f0"
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
	DupEntries = $true
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
	AbsolutePaths = $false
	SystemResolution = $true
	Update = $false
	UpdateMsg = $true
	Log = $false
	LogMsg = $true
	Safe = $false
	NoAuto = $false
	Batch = $false
}

$script:stat = [PSCustomObject]@{
	Err = 0
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
	DupEntries = 0
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

$script:ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage, [System.Text.EncoderExceptionFallback]::new(), [System.Text.DecoderExceptionFallback]::new())
$script:utf = [System.Text.UTF8Encoding]::new($false, $true)
$script:regexOpt = [System.Text.RegularExpressions.RegexOptions]::Compiled
$script:regexDupSep = [regex]::new('\\{2,}', $script:regexOpt)
$script:regexDrive = [regex]::new('^[a-zA-Z]:', $script:regexOpt)

function Show-Menu {
	$restart = $true
	while ($restart) {
		Invoke-ClearHost
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		if ($script:files.Count -eq 0) {
			Write-Host 'Файлы контрольных сумм: Нет' -ForegroundColor Red
		} elseif ($script:files.Count -eq 1) {
			Write-Host ('Файл контрольных сумм: ' + (Remove-LongPrefix $script:files[0].FullName))
		} else {
			Write-Host ('Файлов контрольных сумм: ' + $script:files.Count)
		}
		if ($script:auto) {
			if ($script:opt.NoAuto) {
				Write-Host 'Пути поиска: Нет'
			} else {
				Write-Host 'Пути поиска: Авто'
			}
		} elseif ($script:paths.Count -eq 1) {
			Write-Host ('Путь поиска: ' + (Remove-LongPrefix $script:paths[0]))
		} else {
			Write-Host ('Путей поиска: ' + $script:paths.Count)
		}
		Write-Host ''
		if ($script:files.Count -gt 0) {
			Write-Host '1.  [Начать проверку]' -ForegroundColor Green
		} else {
			Write-Host '1.  [Начать проверку]' -ForegroundColor DarkGreen
		}
		Write-Host ''
		if ($script:opt.DupEntries) {
			Write-Host '2.  Проверять ' -NoNewline
			Write-Host 'дублирующиеся записи' -ForegroundColor Cyan -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '2.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'дублирующиеся записи' -ForegroundColor DarkCyan -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:opt.MissingFiles) {
			Write-Host '3.  Проверять ' -NoNewline
			Write-Host 'отсутствующие файлы' -ForegroundColor Magenta -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '3.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'отсутствующие файлы' -ForegroundColor DarkMagenta -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:auto -and $script:opt.NoAuto) {
			Write-Host '4.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'отсутствующие записи' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Недоступно' -ForegroundColor DarkGray
		} elseif ($script:opt.MissingEntries) {
			Write-Host '4.  Проверять ' -NoNewline
			Write-Host 'отсутствующие записи' -ForegroundColor Yellow -NoNewline
			Write-Host ': Да'
		} else {
			Write-Host '4.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'отсутствующие записи' -ForegroundColor DarkYellow -NoNewline
			Write-Host ': Нет' -ForegroundColor DarkGray
		}
		if ($script:opt.VerifyHashes -eq [HashMode]::All) {
			Write-Host '5.  Проверять ' -NoNewline
			Write-Host 'хэши' -ForegroundColor Red -NoNewline
			Write-Host ' (медленно): Все'
		} elseif ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) {
			Write-Host '5.  Проверять ' -NoNewline
			Write-Host 'хэши' -ForegroundColor Red -NoNewline
			Write-Host ' (медленно): По путям поиска'
		} else {
			Write-Host '5.  Проверять ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'хэши' -ForegroundColor DarkRed -NoNewline
			Write-Host ' (медленно): Нет' -ForegroundColor DarkGray
		}
		Write-Host ''
		Write-Host '6.  Режимы фильтра'
		Write-Host ''
		if ($script:opt.MissingEntries -or ($script:opt.VerifyHashes -ne [HashMode]::No)) {
			if ($script:opt.Verbose) {
				Write-Host '7.  Подробный режим ' -NoNewline
				Write-Host 'хэшей' -ForegroundColor Green -NoNewline
				Write-Host ': Да'
			} else {
				Write-Host '7.  Подробный режим ' -ForegroundColor DarkGray -NoNewline
				Write-Host 'хэшей' -ForegroundColor DarkGreen -NoNewline
				Write-Host ': Нет' -ForegroundColor DarkGray
			}
		} else {
			Write-Host '7.  Подробный режим ' -ForegroundColor DarkGray -NoNewline
			Write-Host 'хэшей' -ForegroundColor DarkGreen -NoNewline
			Write-Host ': Недоступно' -ForegroundColor DarkGray
		}
		if ($script:opt.MissingEntries) {
			if ($script:opt.AbsolutePaths) {
				Write-Host '8.  Пути отсутствующих записей: Абсолютные'
			} else {
				Write-Host '8.  Пути отсутствующих записей: Относительные'
			}
		} else {
			Write-Host '8.  Пути отсутствующих записей: Недоступно' -ForegroundColor DarkGray
		}
		if ($script:opt.SystemResolution) {
			Write-Host '9.  Режим нормализации путей: Системный'
		} else {
			Write-Host '9.  Режим нормализации путей: Внутренний'
		}
		Write-Host ''
		Write-Host '10. Обзор файлов контрольных сумм и путей поиска'
		Write-Host ''
		Write-Host '0.  Выход'
		Write-Host ''
		$read = Read-Host 'Выберите пункт меню (0-10)'
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
				$script:opt.DupEntries = -not $script:opt.DupEntries
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
				$script:opt.SystemResolution = -not $script:opt.SystemResolution
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
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		if ($script:opt.MissingEntries) {
			Write-Host 'Фильтр проверки отсутствующих записей' -ForegroundColor Yellow
			Write-Host ''
			if ($script:opt.EntInclude) {
				Write-Host ('1. Включить файлы по маске: ' + ($script:opt.EntInclude -join '|'))
			} else {
				Write-Host '1. Включить файлы по маске: Нет' -ForegroundColor DarkGray
			}
			if ($script:opt.EntExclude) {
				Write-Host ('2. Исключить файлы по маске: ' + ($script:opt.EntExclude -join '|'))
			} else {
				Write-Host '2. Исключить файлы по маске: Нет' -ForegroundColor DarkGray
			}
			if ($script:opt.EntTime -gt 0) {
				Write-Host ('3. Время изменения файла (' + (Get-TimeUnit $script:opt.EntTimeUnit) + '): ' + $script:opt.EntTime)
			} else {
				Write-Host '3. Время изменения файла: Нет' -ForegroundColor DarkGray
			}
		} else {
			Write-Host 'Фильтр проверки отсутствующих записей' -ForegroundColor DarkYellow
			Write-Host ''
			Write-Host '1. Включить файлы по маске: Недоступно' -ForegroundColor DarkGray
			Write-Host '2. Исключить файлы по маске: Недоступно' -ForegroundColor DarkGray
			Write-Host '3. Время изменения файла: Недоступно' -ForegroundColor DarkGray
		}
		Write-Host ''
		if ($script:opt.VerifyHashes -ne [HashMode]::No) {
			Write-Host 'Фильтр проверки хэшей' -ForegroundColor Red
			Write-Host ''
			if ($script:opt.HashInclude) {
				Write-Host ('4. Включить файлы по маске: ' + ($script:opt.HashInclude -join '|'))
			} else {
				Write-Host '4. Включить файлы по маске: Нет' -ForegroundColor DarkGray
			}
			if ($script:opt.HashExclude) {
				Write-Host ('5. Исключить файлы по маске: ' + ($script:opt.HashExclude -join '|'))
			} else {
				Write-Host '5. Исключить файлы по маске: Нет' -ForegroundColor DarkGray
			}
			if ($script:opt.HashTime -gt 0) {
				Write-Host ('6. Время изменения файла (' + (Get-TimeUnit $script:opt.HashTimeUnit) + '): ' + $script:opt.HashTime)
			} else {
				Write-Host '6. Время изменения файла: Нет' -ForegroundColor DarkGray
			}
		} else {
			Write-Host 'Фильтр проверки хэшей' -ForegroundColor DarkRed
			Write-Host ''
			Write-Host '4. Включить файлы по маске: Недоступно' -ForegroundColor DarkGray
			Write-Host '5. Исключить файлы по маске: Недоступно' -ForegroundColor DarkGray
			Write-Host '6. Время изменения файла: Недоступно' -ForegroundColor DarkGray
		}
		Write-Host ''
		Write-Host '0. [Назад в меню]' -ForegroundColor Green
		Write-Host ''
		$read = Read-Host 'Выберите пункт меню (0-6)'
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
		$masks = @(Get-FileMask (Read-Host 'Маска файла') -ErrSkip)
	} catch {
		$masks = @()
	}
	switch ($maskMode) {
		([MaskMode]::EntInclude) {
			$script:opt.EntInclude = $masks
			break
		}
		([MaskMode]::EntExclude) {
			$script:opt.EntExclude = $masks
			break
		}
		([MaskMode]::HashInclude) {
			$script:opt.HashInclude = $masks
			break
		}
		([MaskMode]::HashExclude) {
			$script:opt.HashExclude = $masks
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
		$read = Read-Host 'Выберите единицу времени (1-5)'
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
		$read = Read-Host ('Время с момента изменения файла (' + (Get-TimeUnit $unit) + ')')
		$time = [int]$read
		Test-TimeValue $unit $time
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
		Invoke-ClearHost
		Write-Host '╔═══════════════════════════════════╗'
		Write-Host '║ Проверка списков контрольных сумм ║'
		Write-Host '╚═══════════════════════════════════╝'
		Write-Host ''
		if ($script:auto -and (-not $script:opt.NoAuto)) {
			if ($script:files.Count -eq 0) {
				Write-Host 'Файлы контрольных сумм: Нет' -ForegroundColor Red
				Write-Host ''
			} else {
				foreach ($file in $script:files) {
					Write-Host ('Файл контрольных сумм: ' + (Remove-LongPrefix $file.FullName))
					$fileDir = Add-LongPrefix $file.DirectoryName
					$baseDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
					if ([System.IO.Directory]::Exists($baseDir)) {
						Write-Host ('Путь поиска: ' + (Remove-LongPrefix $baseDir))
					} else {
						Write-Host ('Путь поиска: ' + (Remove-LongPrefix $fileDir))
					}
					Write-Host ''
				}
			}
		} else {
			if ($script:files.Count -eq 0) {
				Write-Host 'Файлы контрольных сумм: Нет' -ForegroundColor Red
			} elseif ($script:files.Count -eq 1) {
				Write-Host ('Файл контрольных сумм: ' + (Remove-LongPrefix $script:files[0].FullName))
			} else {
				Write-Host 'Файлы контрольных сумм:'
				foreach ($file in $script:files) { Write-Host (Remove-LongPrefix $file.FullName) }
			}
			Write-Host ''
			if ($script:auto -and $script:opt.NoAuto) {
				Write-Host 'Пути поиска: Нет'
			} else {
				if ($script:paths.Count -eq 1) {
					Write-Host ('Путь поиска: ' + (Remove-LongPrefix $script:paths[0]))
				} else {
					Write-Host 'Пути поиска:'
					foreach ($path in $script:paths) { Write-Host (Remove-LongPrefix $path) }
				}
			}
			Write-Host ''
		}
		$ret = $true
		while ($ret) {
			Write-Host 'Задать новые файлы и пути? (Да / ' -NoNewline
			Write-Host '[Нет]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$ret = $false
					break
				}
				'^(y|yes|д|да)$' {
					Write-Host ''
					Show-NewPaths
					$restart = $true
					$ret = $false
					break
				}
				'^(n|no|н|нет)$' {
					$ret = $false
					break
				}
			}
		}
	}
}

function Show-NewPaths {
	$read = Read-Host 'Файлы контрольных сумм'
	if ($read) { Parse-Args $read -Files }
	Write-Host ''
	$read = Read-Host 'Пути поиска'
	if ($read) {
		Parse-Args $read -Paths -ErrPause
		$script:auto = $script:paths.Count -eq 0
	} elseif (-not $script:auto) {
		$ret = $true
		while ($ret) {
			Write-Host ''
			Write-Host 'Очистить пути поиска? (Да / ' -NoNewline
			Write-Host '[Нет]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$ret = $false
					break
				}
				'^(y|yes|д|да)$' {
					$script:paths = @()
					$script:auto = $true
					$ret = $false
					break
				}
				'^(n|no|н|нет)$' {
					$ret = $false
					break
				}
			}
		}
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
								$script:opt.DupEntries = $false
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
								$script:opt.SystemResolution = $false
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
							'^(-b|--batch)$' {
								$script:opt.Batch = $true
								break
							}
							'^--missing-entries-include=$' {
								$script:opt.EntInclude = @(Get-FileMask $argVal)
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-exclude=$' {
								$script:opt.EntExclude = @(Get-FileMask $argVal)
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-minutes=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Minutes) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Minutes
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-hours=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Hours) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Hours
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-days=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Days) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Days
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-months=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Months) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Months
								$script:opt.MissingEntries = $true
								break
							}
							'^--missing-entries-years=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Years) $intVal
								$script:opt.EntTime = $intVal
								$script:opt.EntTimeUnit = [TimeUnit]::Years
								$script:opt.MissingEntries = $true
								break
							}
							'^--hashes-include=$' {
								$script:opt.HashInclude = @(Get-FileMask $argVal)
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-exclude=$' {
								$script:opt.HashExclude = @(Get-FileMask $argVal)
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-minutes=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Minutes) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Minutes
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-hours=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Hours) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Hours
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-days=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Days) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Days
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-months=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Months) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Months
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							'^--hashes-years=$' {
								$intVal = [int]$argVal
								Test-TimeValue ([TimeUnit]::Years) $intVal
								$script:opt.HashTime = $intVal
								$script:opt.HashTimeUnit = [TimeUnit]::Years
								if ($script:opt.VerifyHashes -eq [HashMode]::No) { $script:opt.VerifyHashes = [HashMode]::All }
								break
							}
							default { throw }
						}
					}
				} catch {
					Write-Host ('Недопустимый параметр: ' + $argRaw) -ForegroundColor Red
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
				if (-not $argDir) { $argDir = $script:curDir }
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
					if (-not $Files) { $pathArgs[$argName] = $null }
				} elseif ((-not $sep) -and $script:algorithms.ContainsKey($argObj.Extension)) {
					$fileArgs[$argName] = $argObj
				} elseif (-not $Files) {
					$pathArgs[$argName] = $null
				}
			}
		} catch {
			Write-Host ('Путь не найден: ' + $argRaw) -ForegroundColor Red
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
	if ($Path.StartsWith('\\.\', [System.StringComparison]::Ordinal)) {
		return $Path
	} elseif ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
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
	if ($Path.StartsWith('\\.\', [System.StringComparison]::Ordinal)) {
		return $Path
	} elseif ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
		return '\\' + $Path.Substring(8)
	} elseif ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
		return $Path.Substring(4)
	} else {
		return $Path
	}
}

function Get-LongPath {
	param(
		[string]$Path,
		[string]$BaseDir
	)
	if ($script:opt.SystemResolution -or [string]::IsNullOrEmpty($Path)) { return Add-LongPrefix ([System.IO.Path]::GetFullPath($Path)) }
	if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { return $Path }
	$normal = Remove-LongPrefix $Path.Replace('/', '\')
	$uncPath = $normal.StartsWith('\\', [System.StringComparison]::Ordinal)
	$normal = $script:regexDupSep.Replace($normal, '\')
	if ($uncPath) {
		$normal = '\' + $normal
		$root = Remove-LongPrefix ([System.IO.Path]::GetPathRoot((Add-LongPrefix $normal)))
		if ($normal -eq $root) { return Add-LongPrefix $root }
		$root = $root.TrimEnd('\') + '\'
		$relative = $normal.Substring($root.Length).TrimStart('\')
	} elseif ($script:regexDrive.IsMatch($normal)) {
		$root = (Remove-LongPrefix ([System.IO.Path]::GetPathRoot((Add-LongPrefix $normal)))).TrimEnd('\') + '\'
		if ($normal -eq $root) { return Add-LongPrefix $root }
		if ($normal.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
			$relative = $normal.Substring($root.Length).TrimStart('\')
		} elseif ($normal.StartsWith($root.Substring(0, 2), [System.StringComparison]::OrdinalIgnoreCase)) {
			if ($PSBoundParameters.ContainsKey('BaseDir')) {
				if ($root -eq (Remove-LongPrefix ([System.IO.Path]::GetPathRoot((Add-LongPrefix $BaseDir))))) {
					$current = $BaseDir
				} else {
					$current = [System.IO.Path]::GetFullPath($root.Substring(0, 2) + '.')
				}
			} else {
				$current = [System.IO.Path]::GetFullPath($root.Substring(0, 2) + '.')
			}
			$relative = ([System.IO.Path]::Combine((Remove-LongPrefix $current), $normal.Substring(2))).Substring($root.Length).TrimStart('\')
		}
	} else {
		if ($PSBoundParameters.ContainsKey('BaseDir')) {
			$current = $BaseDir
		} else {
			$current = $script:curDir
		}
		$root = (Remove-LongPrefix ([System.IO.Path]::GetPathRoot((Add-LongPrefix $current)))).TrimEnd('\') + '\'
		if ($normal.StartsWith('\', [System.StringComparison]::Ordinal)) {
			$relative = $normal.TrimStart('\')
		} else {
			$relative = ([System.IO.Path]::Combine((Remove-LongPrefix $current), $normal)).Substring($root.Length).TrimStart('\')
		}
	}
	if (-not $relative) { return Add-LongPrefix $root }
	$builder = [System.Text.StringBuilder]::new()
	$segmBuilder = [System.Text.StringBuilder]::new()
	$skip = 0
	for ($idx = $relative.Length - 1; $idx -ge 0; $idx--) {
		$sep = $false
		$chr = $relative[$idx]
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
						[void]$builder.Append($segm)
						if ($sep) { [void]$builder.Append([char]'\') }
					}
				}
				[void]$segmBuilder.Clear()
			}
		}
	}
	$chars = $builder.ToString().ToCharArray()
	[Array]::Reverse($chars)
	return Add-LongPrefix ([System.IO.Path]::Combine($root, [string]::new($chars).TrimStart('\')))
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
		Write-Log ('Найдено файлов: ' + $newFiles.Count)
	} else {
		Write-Log 'Файлы не найдены!'
		$script:stat.SearchEmpty++
	}
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

function Get-FileTime {
	param(
		[TimeUnit]$Unit,
		[int]$Time
	)
	try {
		switch ($Unit) {
			([TimeUnit]::Minutes) { return $script:start.AddMinutes(-$Time) }
			([TimeUnit]::Hours) { return $script:start.AddHours(-$Time) }
			([TimeUnit]::Days) { return $script:start.AddDays(-$Time) }
			([TimeUnit]::Months) { return $script:start.AddMonths(-$Time) }
			([TimeUnit]::Years) { return $script:start.AddYears(-$Time) }
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
	$masks = [ordered]@{}
	foreach ($mask in @($Value -split '\|' | Where-Object { $_ -ne '' })) {
		try {
			[void]('' -like $mask)
			$masks[$mask.Replace('/', '\')] = $null
		} catch {
			if (-not $ErrSkip) { throw }
		}
	}
	if ($masks.Count -eq 0) { throw }
	return $masks.Keys
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
		[string[]]$Masks
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
	return $match
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
		[int]$Time
	)
	if ($Time -le 0) { throw }
	if ($null -eq (Get-FileTime $Unit $Time)) { throw }
}

function Write-Log {
	param(
		[string]$Value,
		[ConsoleColor]$ForegroundColor,
		[DateTime]$Time,
		[switch]$NoHost
	)
	if (-not $NoHost) {
		if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
			Write-Host $Value -ForegroundColor $ForegroundColor
		} else {
			Write-Host $Value
		}
	}
	if ($Value) {
		if (-not $PSBoundParameters.ContainsKey('Time')) { $Time = Get-Date }
		$script:log.Add('[' + $Time.ToString('yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Value)
	} else {
		$script:log.Add('')
	}
}

function Write-Err {
	param(
		[object]$Err
	)
	$errMsg = $null
	if ($Err.Exception -and $Err.Exception.InnerException) { $errMsg = $Err.Exception.InnerException.Message }
	if (-not $errMsg) { $errMsg = $Err.ToString() }
	Write-Log ('Ошибка выполнения: ' + $errMsg) -ForegroundColor Red
	$script:stat.Err++
}

function Invoke-ClearHost {
	if ($script:opt.Batch) {
		Write-Host ''
	} else {
		Clear-Host
	}
}

function Invoke-Pause {
	if (-not $script:opt.Batch) {
		Write-Host ''
		pause
	}
}

$script:start = Get-Date
$script:curDir = Add-LongPrefix $env:CURDIR
$batFile = Add-LongPrefix $env:BATFILE
$script:files = @()
$script:paths = @()
Parse-Args $env:CMDARGS -ErrPause
$script:auto = $script:paths.Count -eq 0
if (($script:files.Count -eq 0) -and (-not $script:opt.NoAuto)) {
	$script:files = @(Get-ChildItem -LiteralPath $script:curDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $script:algorithms.ContainsKey($_.Extension) })
}
if ($script:auto -and $script:opt.NoAuto) {
	$script:opt.MissingEntries = $false
	if ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) { $script:opt.VerifyHashes = [HashMode]::No }
}
if ($script:opt.ShowMenu) {
	Show-Menu
	$script:start = Get-Date
}
if ($script:files.Count -eq 0) {
	Write-Host 'Файлы контрольных сумм не найдены!' -ForegroundColor Red
	Write-Host 'Поддерживаемые форматы файлов: .sfv, .md5, .sha1, .sha256, .sha384, .sha512' -ForegroundColor Red
	Invoke-Pause
	exit 1
}
Invoke-ClearHost
$script:log = [System.Collections.Generic.List[string]]::new()
Write-Log 'Начало проверки' -Time $script:start -NoHost
Write-Log '' -NoHost
$regexPatterns = @{
	'.sfv' = [regex]::new('^(.*?)\s+([a-fA-F0-9]{8})$', $script:regexOpt)
	'.md5' = [regex]::new('^([a-fA-F0-9]{32})\s+\*?(.*)$', $script:regexOpt)
	'.sha1' = [regex]::new('^([a-fA-F0-9]{40})\s+\*?(.*)$', $script:regexOpt)
	'.sha256' = [regex]::new('^([a-fA-F0-9]{64})\s+\*?(.*)$', $script:regexOpt)
	'.sha384' = [regex]::new('^([a-fA-F0-9]{96})\s+\*?(.*)$', $script:regexOpt)
	'.sha512' = [regex]::new('^([a-fA-F0-9]{128})\s+\*?(.*)$', $script:regexOpt)
}
$entFileTime = $null
if ($script:opt.EntTime -gt 0) {
	$entFileTime = Get-FileTime $script:opt.EntTimeUnit $script:opt.EntTime
}
$hashFileTime = $null
if ($script:opt.HashTime -gt 0) {
	$hashFileTime = Get-FileTime $script:opt.HashTimeUnit $script:opt.HashTime
}
$hashes = @{}
$updObjects = [ordered]@{}
$newFiles = [ordered]@{}
if (($script:opt.MissingEntries -or ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths)) -and (-not $script:auto)) {
	if ($script:paths.Count -eq 1) {
		Write-Log ('Путь поиска: ' + (Remove-LongPrefix $script:paths[0]))
	} else {
		Write-Log 'Пути поиска:'
		foreach ($path in $script:paths) { Write-Log (Remove-LongPrefix $path) }
	}
	if ($script:opt.MissingEntries) {
		$script:stat.Err = 0
		$newFiles = Get-NewFiles $script:paths
		$script:stat.GlobalErr += $script:stat.Err
		if ($script:stat.Err) { Write-Log ('Ошибок выполнения: ' + $script:stat.Err) -ForegroundColor Red }
	}
	Write-Log ''
}
foreach ($file in $script:files) {
	$script:stat.Err = 0
	$fileName = Add-LongPrefix $file.FullName
	$fileDir = Add-LongPrefix $file.DirectoryName
	$fileExt = $file.Extension
	$fileStat = [PSCustomObject]@{
		EntChecked = 0
		EntSkipped = 0
		DupEntries = 0
		MissingEntries = 0
		MissingFiles = 0
		HashCalculated = 0
		HashNotCalculated = 0
		HashMismatches = 0
	}
	$skipStat = $false
	Write-Log ('Проверка файла: ' + (Remove-LongPrefix $fileName))
	if (($script:opt.MissingEntries -or ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths)) -and $script:auto) {
		$newFiles = [ordered]@{}
		$baseDir = [System.IO.Path]::Combine($fileDir, $file.BaseName)
		if ([System.IO.Directory]::Exists($baseDir)) {
			$script:paths = @($baseDir)
		} else {
			$script:paths = @($fileDir)
		}
		Write-Log ('Путь поиска: ' + (Remove-LongPrefix $script:paths[0]))
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
				if ($algorithm -eq 'CRC32') {
					if (-not $line.TrimStart().StartsWith(';', [System.StringComparison]::Ordinal)) {
						$ent = $match.Groups[1].Value
						$entHash = $match.Groups[2].Value
					}
				} else {
					$entHash = $match.Groups[1].Value
					$ent = $match.Groups[2].Value
				}
			}
			if ($ent) {
				try {
					if ([System.IO.Path]::IsPathRooted($ent)) {
						$entPath = Get-LongPath $ent $fileDir
					} else {
						$entPath = Get-LongPath ([System.IO.Path]::Combine((Remove-LongPrefix $fileDir), $ent))
					}
				} catch {
					Write-Err $_
					Write-Log ('Ошибка в записи: ' + $ent) -ForegroundColor Red
					$ent = $null
				}
			}
			if ($ent) {
				$fileStat.EntChecked++
				$entKey = $entPath
				if ($keys.ContainsKey($entKey)) {
					$fileStat.DupEntries++
					if ($script:opt.DupEntries) {
						Write-Log ('Дублируется запись: ' + $ent) -ForegroundColor Cyan
						continue
					} else {
						$entKey = '<DUP' + $fileStat.DupEntries + '>'
					}
				} else {
					$keys[$entKey] = $null
				}
				$fileExist = Test-FileExist $entPath
				if ($fileExist) {
					$entLine = $line
					if ($script:opt.VerifyHashes -ne [HashMode]::No) {
						$verifyHash = $true
						if (($null -ne $hashFileTime) -and (-not (Test-FileTime $entPath $hashFileTime))) { $verifyHash = $false }
						if ($verifyHash -and ($script:opt.HashInclude.Count -gt 0) -and (-not (Test-FileMask $entPath $script:opt.HashInclude))) { $verifyHash = $false }
						if ($verifyHash -and ($script:opt.HashExclude.Count -gt 0) -and (Test-FileMask $entPath $script:opt.HashExclude)) { $verifyHash = $false }
						if ($verifyHash -and ($script:opt.VerifyHashes -eq [HashMode]::SearchPaths) -and (-not (Test-FilePath $entPath $script:paths))) { $verifyHash = $false }
						if ($verifyHash) {
							$hashKey = '<' + $algorithm + '>' + $entPath
							$hash = $hashes[$hashKey]
							if ($null -eq $hash) {
								$hash = Get-HashValue $entPath $algorithm
								if ($null -ne $hash) { $hashes[$hashKey] = $hash }
							}
							if ($null -eq $hash) {
								Write-Log ('Не удалось вычислить хэш: ' + $ent) -ForegroundColor Red
								$fileStat.HashNotCalculated++
							} else {
								if ($entHash -ne $hash) {
									Write-Log ('Хэш не совпал: ' + $ent) -ForegroundColor Red
									$fileStat.HashMismatches++
									$entLine = Get-EntLine $ent $hash $algorithm
								} elseif ($script:opt.Verbose) {
									Write-Log ('Хэш совпал: ' + $ent) -ForegroundColor Green
								}
								$fileStat.HashCalculated++
							}
						}
					}
					$entries[$entKey] = $entLine
				} elseif (($null -ne $fileExist) -and $script:opt.MissingFiles) {
					Write-Log ('Отсутствует файл: ' + $ent) -ForegroundColor Magenta
					$fileStat.MissingFiles++
				} else {
					$entries[$entKey] = $line
				}
			} else {
				$fileStat.EntSkipped++
				$entries['<SKIP' + $fileStat.EntSkipped + '>'] = $line
			}
		}
		$baseDir = $fileDir.TrimEnd('\') + '\'
		foreach ($entPath in $newFiles.Keys) {
			if ($entries.Contains($entPath)) { continue }
			if (($entPath -eq $fileName) -or ($entPath -eq $batFile)) { continue }
			if (($null -ne $entFileTime) -and (-not (Test-FileTime $entPath $entFileTime))) { continue }
			if (($script:opt.EntInclude.Count -gt 0) -and (-not (Test-FileMask $entPath $script:opt.EntInclude))) { continue }
			if (($script:opt.EntExclude.Count -gt 0) -and (Test-FileMask $entPath $script:opt.EntExclude)) { continue }
			if ((-not $script:opt.AbsolutePaths) -and $entPath.StartsWith($baseDir, [System.StringComparison]::OrdinalIgnoreCase)) {
				$ent = $entPath.Substring($baseDir.Length).TrimStart('\')
			} else {
				$ent = Remove-LongPrefix $entPath
			}
			Write-Log ('Отсутствует запись: ' + $ent) -ForegroundColor Yellow
			$fileStat.MissingEntries++
			$newEntries[$entPath] = $ent
		}
	} catch {
		Write-Err $_
		Write-Log 'Не удалось проверить файл!' -ForegroundColor Red
		$script:stat.FilesNotChecked++
		$skipStat = $true
	}
	$listErr = $false
	$warnings = $false
	$entDel = 0
	if ($script:stat.Err) {
		$script:stat.CheckErr += $script:stat.Err
		Write-Log ('Ошибок выполнения: ' + $script:stat.Err) -ForegroundColor Red
	}
	if ($skipStat) {
		Write-Log ''
		continue
	}
	if ($fileStat.EntChecked) {
		Write-Log ('Проверено записей: ' + $fileStat.EntChecked)
		$script:stat.EntChecked += $fileStat.EntChecked
	} else {
		Write-Log 'Записи в файлах контрольных сумм не найдены!' -ForegroundColor Yellow
		$script:stat.FilesEmpty++
		$warnings = $true
	}
	if ($script:opt.MissingEntries -and (($script:auto -and ($newFiles.Count -eq 0)) -or (($script:files.Count -eq 1) -and $script:stat.SearchEmpty))) {
		Write-Log 'Файлы по путям поиска не найдены!' -ForegroundColor Yellow
		$warnings = $true
	}
	if ($fileStat.EntSkipped) {
		Write-Log ('Пропущено строк: ' + $fileStat.EntSkipped)
		$script:stat.EntSkipped += $fileStat.EntSkipped
	}
	if ($script:opt.DupEntries -and $fileStat.DupEntries) {
		Write-Log ('Дублирующихся записей: ' + $fileStat.DupEntries) -ForegroundColor Cyan
		$script:stat.DupEntries += $fileStat.DupEntries
		$entDel += $fileStat.DupEntries
		$listErr = $true
	}
	if ($fileStat.MissingFiles) {
		Write-Log ('Отсутствующих файлов: ' + $fileStat.MissingFiles) -ForegroundColor Magenta
		$script:stat.MissingFiles += $fileStat.MissingFiles
		$entDel += $fileStat.MissingFiles
		$listErr = $true
	}
	if ($fileStat.MissingEntries) {
		Write-Log ('Отсутствующих записей: ' + $fileStat.MissingEntries) -ForegroundColor Yellow
		$script:stat.MissingEntries += $fileStat.MissingEntries
		$listErr = $true
	}
	if ($fileStat.HashCalculated) {
		Write-Log ('Вычислено хэшей: ' + $fileStat.HashCalculated)
		$script:stat.HashCalculated += $fileStat.HashCalculated
	}
	if ($fileStat.HashNotCalculated) {
		Write-Log ('Не вычислено хэшей: ' + $fileStat.HashNotCalculated) -ForegroundColor Red
		$script:stat.HashNotCalculated += $fileStat.HashNotCalculated
	}
	if ($fileStat.HashMismatches) {
		Write-Log ('Не совпало хэшей: ' + $fileStat.HashMismatches) -ForegroundColor Red
		$script:stat.HashMismatches += $fileStat.HashMismatches
		$listErr = $true
	}
	if ($listErr -and (-not ($script:opt.Safe -and ($script:stat.Err -or $script:stat.GlobalErr)))) {
		$updObjects[$fileName] = [PSCustomObject]@{
			Algorithm = $algorithm
			Encoding = $encoding
			Entries = $entries
			NewEntries = $newEntries
			EntDeleted = $entDel
			EntUpdated = $fileStat.HashMismatches
			EntAdded = 0
			EntNotAdded = 0
		}
	}
	if ($script:stat.Err -or $script:stat.GlobalErr) {
		Write-Log 'Проверка файла выполнена с ошибками!' -ForegroundColor Red
		$script:stat.FilesCheckedErr++
	} else {
		if (-not ($listErr -or $warnings)) {
			Write-Log 'Проверка файла выполнена успешно!' -ForegroundColor Green
		}
		$script:stat.FilesChecked++
	}
	Write-Log ''
}
Write-Log 'Проверка завершена!'
$script:stat.CheckErr += $script:stat.GlobalErr
if ($script:files.Count -ne 1) {
	Write-Log ''
	$listErr = $false
	$warnings = $false
	if ($script:stat.CheckErr) { Write-Log ('Ошибок выполнения: ' + $script:stat.CheckErr) -ForegroundColor Red }
	if ($script:stat.FilesChecked) { Write-Log ('Проверено файлов контрольных сумм: ' + $script:stat.FilesChecked) }
	if ($script:stat.FilesCheckedErr) { Write-Log ('Проверено файлов контрольных сумм с ошибками: ' + $script:stat.FilesCheckedErr) -ForegroundColor Red }
	if ($script:stat.FilesNotChecked) { Write-Log ('Не проверено файлов контрольных сумм: ' + $script:stat.FilesNotChecked) -ForegroundColor Red }
	if ($script:stat.EntChecked) { Write-Log ('Проверено записей: ' + $script:stat.EntChecked) }
	if ($script:stat.FilesEmpty) {
		if ($script:stat.EntChecked) {
			Write-Log ('Записи в файлах контрольных сумм не найдены: ' + $script:stat.FilesEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Записи в файлах контрольных сумм не найдены!' -ForegroundColor Yellow
		}
		$warnings = $true
	}
	if ($script:stat.SearchEmpty) {
		if ($script:auto) {
			Write-Log ('Файлы по путям поиска не найдены: ' + $script:stat.SearchEmpty) -ForegroundColor Yellow
		} else {
			Write-Log 'Файлы по путям поиска не найдены!' -ForegroundColor Yellow
		}
		$warnings = $true
	}
	if ($script:stat.EntSkipped) { Write-Log ('Пропущено строк: ' + $script:stat.EntSkipped) }
	if ($script:stat.DupEntries) {
		Write-Log ('Дублирующихся записей: ' + $script:stat.DupEntries) -ForegroundColor Cyan
		$listErr = $true
	}
	if ($script:stat.MissingFiles) {
		Write-Log ('Отсутствующих файлов: ' + $script:stat.MissingFiles) -ForegroundColor Magenta
		$listErr = $true
	}
	if ($script:stat.MissingEntries) {
		Write-Log ('Отсутствующих записей: ' + $script:stat.MissingEntries) -ForegroundColor Yellow
		$listErr = $true
	}
	if ($script:stat.HashCalculated) { Write-Log ('Вычислено хэшей: ' + $script:stat.HashCalculated) }
	if ($script:stat.HashNotCalculated) { Write-Log ('Не вычислено хэшей: ' + $script:stat.HashNotCalculated) -ForegroundColor Red }
	if ($script:stat.HashMismatches) {
		Write-Log ('Не совпало хэшей: ' + $script:stat.HashMismatches) -ForegroundColor Red
		$listErr = $true
	}
	if ($script:stat.CheckErr -or $script:stat.GlobalErr) {
		Write-Log 'Проверка выполнена с ошибками!' -ForegroundColor Red
	} elseif (-not ($listErr -or $warnings)) {
		Write-Log 'Проверка выполнена успешно!' -ForegroundColor Green
	}
}
$finalPause = $true
if ($updObjects.Count -gt 0) {
	if ($script:opt.UpdateMsg) {
		Write-Host ''
		$ret = $true
		while ($ret) {
			if ($script:stat.CheckErr -or $script:stat.GlobalErr) {
				Write-Host 'Обновить' -ForegroundColor Red -NoNewline
			} else {
				Write-Host 'Обновить' -ForegroundColor Green -NoNewline
			}
			Write-Host ' файлы? (Да / ' -NoNewline
			Write-Host '[Нет]' -ForegroundColor Green -NoNewline
			$read = Read-Host ')'
			switch -Regex ($read.Trim()) {
				'^$' {
					$script:opt.Update = $false
					$ret = $false
					break
				}
				'^(y|yes|д|да)$' {
					$script:opt.Update = $true
					$ret = $false
					break
				}
				'^(n|no|н|нет)$' {
					$script:opt.Update = $false
					$ret = $false
					break
				}
			}
		}
		$finalPause = $false
	}
	if ($script:opt.Update) {
		Write-Log ''
		Write-Log 'Начало обновления' -NoHost
		Write-Log '' -NoHost
		foreach ($fileName in $updObjects.Keys) {
			$script:stat.Err = 0
			$updObj = $updObjects[$fileName]
			$tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($fileName), 'Checksum_List_Checker_' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
			$bakIdx = 0
			$bakFile = $fileName + '.bak'
			$bakExist = $false
			$skipStat = $false
			Write-Log ('Обновление файла: ' + (Remove-LongPrefix $fileName))
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
						if ($script:opt.Safe) { throw [CustomException]::new('Обновление прервано!') }
						$updObj.EntNotAdded++
					} else {
						$updObj.Entries[$entPath] = Get-EntLine $ent $hash $updObj.Algorithm
						if ($script:opt.Verbose) { Write-Log ('Вычислен хэш: ' + $ent) -ForegroundColor Green }
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
				Write-Log ('Создана резервная копия: ' + (Remove-LongPrefix $bakFile))
				[System.IO.File]::Move($tempFile, $fileName)
			} catch [CustomException] {
				Write-Log $_.Exception.Message -ForegroundColor Red
				$script:stat.FilesNotUpdated++
				$skipStat = $true
			} catch {
				Write-Err $_
				Write-Log 'Не удалось обновить файл контрольных сумм!' -ForegroundColor Red
				if ($bakExist -and (-not [System.IO.File]::Exists($fileName)) -and [System.IO.File]::Exists($bakFile)) {
					try {
						[System.IO.File]::Move($bakFile, $fileName)
						Write-Log 'Файл восстановлен из резервной копии!' -ForegroundColor Red
					} catch {
						Write-Err $_
						Write-Log 'Файл не восстановлен из резервной копии!' -ForegroundColor Red
					}
				}
				$script:stat.FilesNotUpdated++
				$skipStat = $true
			} finally {
				if ([System.IO.File]::Exists($tempFile)) {
					try { [System.IO.File]::Delete($tempFile) } catch {}
				}
			}
			if ($script:stat.Err) {
				$script:stat.UpdateErr += $script:stat.Err
				Write-Log ('Ошибок выполнения: ' + $script:stat.Err) -ForegroundColor Red
			}
			if ($skipStat) {
				Write-Log ''
				continue
			}
			if ($updObj.EntDeleted) {
				Write-Log ('Удалено записей: ' + $updObj.EntDeleted)
				$script:stat.EntDeleted += $updObj.EntDeleted
			}
			if ($updObj.EntUpdated) {
				Write-Log ('Обновлено записей: ' + $updObj.EntUpdated)
				$script:stat.EntUpdated += $updObj.EntUpdated
			}
			if ($updObj.EntAdded) {
				Write-Log ('Добавлено записей: ' + $updObj.EntAdded)
				$script:stat.EntAdded += $updObj.EntAdded
			}
			if ($updObj.EntNotAdded) {
				Write-Log ('Не добавлено записей: ' + $updObj.EntNotAdded) -ForegroundColor Red
				$script:stat.EntNotAdded += $updObj.EntNotAdded
			}
			if ($script:stat.Err) {
				Write-Log 'Обновление файла выполнено с ошибками!' -ForegroundColor Red
				$script:stat.FilesUpdatedErr++
			} else {
				Write-Log 'Обновление файла выполнено успешно!' -ForegroundColor Green
				$script:stat.FilesUpdated++
			}
			Write-Log ''
		}
		Write-Log 'Обновление завершено!'
		if ($updObjects.Count -ne 1) {
			Write-Log ''
			if ($script:stat.UpdateErr) { Write-Log ('Ошибок выполнения: ' + $script:stat.UpdateErr) -ForegroundColor Red }
			if ($script:stat.FilesUpdated) { Write-Log ('Обновлено файлов контрольных сумм: ' + $script:stat.FilesUpdated) }
			if ($script:stat.FilesUpdatedErr) { Write-Log ('Обновлено файлов контрольных сумм с ошибками: ' + $script:stat.FilesUpdatedErr) -ForegroundColor Red }
			if ($script:stat.FilesNotUpdated) { Write-Log ('Не обновлено файлов контрольных сумм: ' + $script:stat.FilesNotUpdated) -ForegroundColor Red }
			if ($script:stat.EntDeleted) { Write-Log ('Удалено записей: ' + $script:stat.EntDeleted) }
			if ($script:stat.EntUpdated) { Write-Log ('Обновлено записей: ' + $script:stat.EntUpdated) }
			if ($script:stat.EntAdded) { Write-Log ('Добавлено записей: ' + $script:stat.EntAdded) }
			if ($script:stat.EntNotAdded) { Write-Log ('Не добавлено записей: ' + $script:stat.EntNotAdded) -ForegroundColor Red }
			if ($script:stat.UpdateErr) {
				Write-Log 'Обновление выполнено с ошибками!' -ForegroundColor Red
			} else {
				Write-Log 'Обновление выполнено успешно!' -ForegroundColor Green
			}
		}
		$finalPause = $true
	}
}
if ($script:opt.LogMsg) {
	Write-Host ''
	$ret = $true
	while ($ret) {
		Write-Host 'Сохранить журнал проверки? (Да / ' -NoNewline
		Write-Host '[Нет]' -ForegroundColor Green -NoNewline
		$read = Read-Host ')'
		switch -Regex ($read.Trim()) {
			'^$' {
				$script:opt.Log = $false
				$ret = $false
				break
			}
			'^(y|yes|д|да)$' {
				$script:opt.Log = $true
				$ret = $false
				break
			}
			'^(n|no|н|нет)$' {
				$script:opt.Log = $false
				$ret = $false
				break
			}
		}
	}
	$finalPause = $false
}
$logErr = $false
if ($script:opt.Log) {
	Write-Host ''
	$tempFile = [System.IO.Path]::Combine($script:curDir, 'Check_Log_' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
	$logIdx = 0
	$logName = 'Check_Log_' + $script:start.ToString('yyyy-MM-dd_HH-mm-ss')
	$logFile = [System.IO.Path]::Combine($script:curDir, $logName + '.txt')
	try {
		[System.IO.File]::WriteAllLines($tempFile, $script:log, $script:utf)
		while ($true) {
			try {
				[System.IO.File]::Move($tempFile, $logFile)
				break
			} catch [System.IO.IOException] {
				if (($_.Exception.HResult -band 0xFFFF) -in 0x50, 0xB7) {
					$logIdx++
					$logFile = [System.IO.Path]::Combine($script:curDir, $logName + ' (' + $logIdx + ').txt')
				} else {
					throw
				}
			}
		}
		Write-Host ('Журнал проверки сохранён в файл: ' + (Remove-LongPrefix $logFile))
	} catch {
		Write-Err $_
		Write-Host 'Не удалось сохранить журнал проверки!' -ForegroundColor Red
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
if ($script:stat.DupEntries) { $exit = $exit -bor 16 }
if ($script:stat.MissingFiles) { $exit = $exit -bor 32 }
if ($script:stat.MissingEntries) { $exit = $exit -bor 64 }
if ($script:stat.HashMismatches) { $exit = $exit -bor 128 }
if ($script:stat.FilesEmpty) { $exit = $exit -bor 256 }
if ($script:stat.SearchEmpty) { $exit = $exit -bor 512 }
if ($logErr) { $exit = $exit -bor 1024 }
exit $exit
