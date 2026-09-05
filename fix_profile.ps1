$file = "D:\DevEco Studio\sdk\default\openharmony\toolchains\lib\UnsgnedDebugProfileTemplate.json"
$content = Get-Content $file -Raw

# Change apl from normal to system_basic
$modified = $content -replace '"apl": "normal"', '"apl": "system_basic"'

# Add ACL permissions
$modified = $modified -replace '"allowed-acls": \[\s*""\s*\]', '"allowed-acls": ["ohos.permission.READ_MEDIA", "ohos.permission.READ_DOCUMENT", "ohos.permission.READ_IMAGEVIDEO", "ohos.permission.READ_AUDIO"]'

# Update restricted-permissions
$modified = $modified -replace '"restricted-permissions": \[\s*""\s*\]', '"restricted-permissions": ["ohos.permission.READ_MEDIA", "ohos.permission.READ_DOCUMENT", "ohos.permission.READ_IMAGEVIDEO", "ohos.permission.READ_AUDIO"]'

$modified | Set-Content $file -Force
Write-Host "=== Modified successfully ==="
Write-Host ""

# Verify changes
Write-Host "=== Verifying apl ==="
Select-String -Path $file -Pattern '"apl"' | ForEach-Object { $_.Line.Trim() }

Write-Host ""
Write-Host "=== Verifying acls ==="
Select-String -Path $file -Pattern 'allowed-acls' -Context 0,3 | ForEach-Object { $_.Line.Trim() }

Write-Host ""
Write-Host "=== Verifying restricted-permissions ==="
Select-String -Path $file -Pattern 'restricted-permissions' -Context 0,3 | ForEach-Object { $_.Line.Trim() }
