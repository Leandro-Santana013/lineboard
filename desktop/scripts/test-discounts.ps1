$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testOutput = Join-Path $workspace ('.local\discount-tests\' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testOutput
$testExecutable = Join-Path $testOutput 'DiscountTests.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /utf8output /target:exe ("/out:" + $testExecutable) /reference:System.Web.Extensions.dll (Join-Path $workspace 'desktop\src\Models.cs') (Join-Path $workspace 'desktop\src\SaleDiscount.cs') (Join-Path $workspace 'desktop\tests\SaleDiscountTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Discount test compilation failed.' }
& $testExecutable
if ($LASTEXITCODE -ne 0) { throw 'Discount tests failed.' }
