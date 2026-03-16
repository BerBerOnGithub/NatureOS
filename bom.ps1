$ext = @(
".bat",".cmd",".ps1",".asm",".c",".cpp",".h",".hpp",
".txt",".py",".js",".ts",".html",".css",".json",".xml"
)

$scanned = 0
$fixed = 0

Get-ChildItem -Recurse -File | Where-Object { $ext -contains $_.Extension.ToLower() } | ForEach-Object {

    $scanned++

    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)

    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {

        Write-Host "Removing BOM:" $_.FullName
        [System.IO.File]::WriteAllBytes($_.FullName, $bytes[3..($bytes.Length-1)])
        $fixed++
    }
}

Write-Host ""
Write-Host "Summary:"
Write-Host "Scanned:" $scanned "files"
Write-Host "Fixed:" $fixed "files"