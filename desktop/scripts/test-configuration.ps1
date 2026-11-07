$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testOutput = Join-Path $workspace ('.local\configuration-tests\' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testOutput
$testExecutable = Join-Path $testOutput 'ConfigurationFileTests.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /utf8output /target:exe ("/out:" + $testExecutable) (Join-Path $workspace 'desktop\src\ConfigurationFile.cs') (Join-Path $workspace 'desktop\tests\ConfigurationFileTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Configuration test compilation failed.' }
& $testExecutable
if ($LASTEXITCODE -ne 0) { throw 'Configuration tests failed.' }
