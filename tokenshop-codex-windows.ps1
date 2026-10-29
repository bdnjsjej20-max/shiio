
$ErrorActionPreference = 'Stop'

function Get-CodexConfigRoot {
    $root = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
    if (-not [IO.Path]::IsPathRooted($root)) { throw 'CODEX_HOME должен содержать абсолютный путь. Настройки не изменены.' }
    return [IO.Path]::GetFullPath($root)
}

function Test-ModuleApiKey([string]$ApiKey) {
    if ($ApiKey -notmatch '^sk-[A-Za-z0-9_-]{10,}$') {
        throw 'Нужен полный API-ключ Token Shop, начинающийся с sk-. Вставьте ключ без кавычек и без слова Bearer.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://token-shop.online/v1/models' `
            -Headers @{ Authorization = ('Bearer ' + $ApiKey) } -TimeoutSec 20 -MaximumRedirection 0
    } catch [Net.WebException] {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        throw "Проверка ключа Token Shop не прошла (HTTP $status). Проверьте ключ и интернет. Настройки не изменены."
    }
    $models = $response.Content | ConvertFrom-Json
    if (-not @($models.data | Where-Object { $_.id -and $_.id -notmatch 'image' }).Count) {
        throw 'Ключ не открыл ни одной текстовой модели. Проверьте доступ к моделям в кабинете Token Shop.'
    }
}

function Get-ConfigFingerprint([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return 'missing' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($File))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Set-ModuleCodexConfig([string]$ConfigRoot) {
    [IO.Directory]::CreateDirectory($ConfigRoot) | Out-Null
    $file = Join-Path $ConfigRoot 'config.toml'
    $backup = Join-Path $ConfigRoot ('config.before-tokenshop-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.toml')

    $beforeContent = ''
    if (Test-Path -LiteralPath $file) {
        $beforeContent = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($backup, $beforeContent, (New-Object Text.UTF8Encoding($false)))
    } else {
        [IO.File]::WriteAllText($backup, '', (New-Object Text.UTF8Encoding($false)))
    }

    $providerBlock = @"
[model_providers.tokenshop]
name = "Token Shop"
base_url = "https://token-shop.online/v1"
env_key = "TOKENSHOP_API_KEY"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
"@

    $lines = if ([string]::IsNullOrWhiteSpace($beforeContent)) { @() } else { $beforeContent -split "\r?\n" }
    $newLines = [System.Collections.Generic.List[string]]::new()
    $inModuleApiTable = $false
    $inMultiline = $false
    $providerSet = $false
    $webSearchSet = $false

    $firstTableIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[[^\]]+\]') {
            $firstTableIndex = $i
            break
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $quoteCount = ([regex]::Matches($line, '"""')).Count
        if ($quoteCount % 2 -ne 0) {
            $inMultiline = -not $inMultiline
        }

        if (-not $inMultiline) {
            if ($line -match '^\s*\[([^\]]+)\]') {
                $tableName = $matches[1].Trim()
                if ($tableName -eq 'model_providers.tokenshop' -or $tableName.StartsWith('model_providers.tokenshop.')) {
                    $inModuleApiTable = $true
                    continue
                } else {
                    $inModuleApiTable = $false
                }
            }

            if ($inModuleApiTable) {
                continue
            }

            if ($firstTableIndex -eq -1 -or $i -lt $firstTableIndex) {
                if ($line -match '^\s*model\s*=') {
                    continue
                }
                if ($line -match '^\s*model_provider\s*=') {
                    $newLines.Add('model_provider = "tokenshop"')
                    $providerSet = $true
                    continue
                }
                if ($line -match '^\s*web_search\s*=') {
                    $newLines.Add('web_search = "disabled"')
                    $webSearchSet = $true
                    continue
                }
            }
        }

        if (-not $inModuleApiTable) {
            $newLines.Add($line)
        }
    }

    $insertIndex = 0
    while ($insertIndex -lt $newLines.Count -and ($newLines[$insertIndex].Trim().StartsWith('#') -or [string]::IsNullOrWhiteSpace($newLines[$insertIndex]))) {
        $insertIndex++
    }

    $topKeys = [System.Collections.Generic.List[string]]::new()
    if (-not $providerSet) { $topKeys.Add('model_provider = "tokenshop"') }
    if (-not $webSearchSet) { $topKeys.Add('web_search = "disabled"') }

    for ($k = $topKeys.Count - 1; $k -ge 0; $k--) {
        $newLines.Insert($insertIndex, $topKeys[$k])
    }

    $crlf = [char]13 + [char]10
    $trimmedBody = ($newLines -join $crlf).Trim()
    $finalContent = if ([string]::IsNullOrWhiteSpace($trimmedBody)) {
        $providerBlock.Trim() + $crlf
    } else {
        $trimmedBody + $crlf + $crlf + $providerBlock.Trim() + $crlf
    }

    [IO.File]::WriteAllText($file, $finalContent, (New-Object Text.UTF8Encoding($false)))
    $afterHash = Get-ConfigFingerprint $file

    return @{ File = $file; Backup = $backup; Fingerprint = $afterHash }
}

function Install-ModuleCodex([string]$ConfigRoot, [string]$ApiKey) {
    Test-ModuleApiKey $ApiKey
    $result = Set-ModuleCodexConfig $ConfigRoot
    try {
        [Environment]::SetEnvironmentVariable('TOKENSHOP_API_KEY', $ApiKey, 'User')
        [Environment]::SetEnvironmentVariable('TOKENSHOP_API_KEY', $ApiKey, 'Process')
    } catch {
        if ((Get-ConfigFingerprint $result.File) -eq $result.Fingerprint) { [IO.File]::Copy($result.Backup, $result.File, $true) }
        throw
    }
    return $result
}

if ($FunctionsOnly) { return }

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$apiKey = $null
try {
    Write-Host ''
    Write-Host 'Token Shop — настройка Codex Desktop для Windows' -ForegroundColor Cyan
    Write-Host 'Выбор модели остаётся в Codex. Адрес: https://token-shop.online/v1'
    Write-Host 'Codex сохранит свой выбор модели; будут изменены провайдер и поиск.'
    Write-Host 'Создаётся резервная копия config.toml. Права администратора не нужны.'
    Write-Host 'Ключ проверяется только на token-shop.online; платная генерация не запускается.'
    Write-Host ''
    $configRoot = Get-CodexConfigRoot
    Write-Host ('Папка настроек: ' + $configRoot)
    # Обычный Read-Host не маскирует ввод и позволяет вставлять ключ из буфера обмена.
    $apiKey = (Read-Host 'Вставьте API-ключ Token Shop и нажмите Enter').Trim()
    Write-Host 'Проверяю ключ и сохраняю настройки...'
    $result = Install-ModuleCodex $configRoot $apiKey
    Write-Host ''
    Write-Host 'ГОТОВО. Ключ принят, Codex подключён к Token Shop.' -ForegroundColor Green
    Write-Host ('Резервная копия: ' + $result.Backup)
    Write-Host 'Полностью закройте Codex Desktop, откройте снова и создайте НОВУЮ локальную задачу.'
    Write-Host 'Введите: Ответь одним словом: работает'
    Write-Host 'Если приложение пишет Missing TOKENSHOP_API_KEY, перезагрузите Windows один раз.'
    Write-Host 'Для возврата прежних настроек закройте Codex и скопируйте резервный файл поверх config.toml.'
    Write-Host 'Ключ сохранён в переменной среды пользователя Windows TOKENSHOP_API_KEY.'
    Write-Host 'Инструкция: https://token-shop.online/docs#codex'
} catch {
    $message = $_.Exception.Message
    if ($apiKey) { $message = $message.Replace($apiKey, '[СКРЫТО]') }
    Write-Host ('ОШИБКА: ' + $message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Write-Host 'Автоматическая настройка не завершена. Сохраните текст ошибки без ключа.'
    exit 1
} finally { $apiKey = $null }
