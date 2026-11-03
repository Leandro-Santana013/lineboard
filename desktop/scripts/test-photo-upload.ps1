param(
    [string]$AssemblyPath = (Join-Path $PSScriptRoot '..\bin\Lineboard.exe'),
    [string]$ImagePath
)
$ErrorActionPreference = 'Stop'
# Exercise the real native message handler without opening a database or
# sending the user's image to Storage. Only the network transport is replaced.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class PhotoProbeTransport {
 public static Func<Dictionary<string,object>,Dictionary<string,object>> Create() {
  return payload => new Dictionary<string,object>{{"photo_path","00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002.jpg"}};
 }
}
'@
if ($ImagePath) { $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($ImagePath)) }
else {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap 1,1
    $stream = New-Object IO.MemoryStream
    try { $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Jpeg); $bytes = $stream.ToArray() }
    finally { $bitmap.Dispose(); $stream.Dispose() }
}
$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AssemblyPath))
$bridgeType = $assembly.GetType('Lineboard.DesktopBridge',$true)
$syncType = $assembly.GetType('Lineboard.CloudSync',$true)
$storeType = $assembly.GetType('Lineboard.SicStore',$true)
$bridge = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($bridgeType)
$sender = [PhotoProbeTransport]::Create()
$constructor = $syncType.GetConstructor([Reflection.BindingFlags]'NonPublic,Instance',$null,[Type[]]@($storeType,$sender.GetType()),$null)
$sync = $constructor.Invoke([object[]]@($null,$sender))
$bridgeType.GetField('sync',[Reflection.BindingFlags]'NonPublic,Instance').SetValue($bridge,$sync)
$request = @{id='photo-regression';action='photo.upload';payload=@{content_type='image/jpeg';data=[Convert]::ToBase64String($bytes)}} | ConvertTo-Json -Compress -Depth 4
$raw = $bridgeType.GetMethod('Process').Invoke($bridge,[object[]]@('https://lineboard.local/',[string]$request))
$result = $raw | ConvertFrom-Json
if (-not $result.ok) { $raw; exit 1 }
Write-Output '{"photo_upload":"passed","transport":"isolated","database_writes":false}'
