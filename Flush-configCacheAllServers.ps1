Add-PSSnapin *SharePoint* -EA 0
$thisServer = $env:COMPUTERNAME
Stop-Service SPTimerV4
$spServers = (Get-SPFarm).servers | Where-Object {$_.Role -ne "Invalid"} | select Address
#region Create Scriptblock to stop SPTimerV4 and clean cache
    $sb1 = {
        $date = Get-Date -UFormat "%Y%m%d"
        $path = "C:\DR Information"
        if (-not(Test-Path $path)) {New-Item $path -ItemType Directory}
        $fileName = "$path\$date- Config Cache Cleanup.txt"
        Stop-Service SPTimerV4
        Get-Service SPTimerV4 | Out-File $fileName
        $files = Get-ChildItem C:\ProgramData\Microsoft\SharePoint\Config -Recurse -Filter 'cache.ini'
        $files | Out-File $fileName -Append
        foreach ($file in $files) {
            $xmlFiles = Get-ChildItem $file.PSParentPath -Recurse -Filter '*.xml'
            $xmlFiles | Out-File $fileName -Append
            $xmlFiles | Remove-Item -Force  
        }
        $cacheFile = Get-Content $file.FullName
        $cacheContent = 1
        Set-Content -Value $cacheContent  -Path $file.FullName
        Get-Content $file.FullName | Out-File $fileName -Append
    }
#endregion

#region Create Scriptblock to restart SPTimerV4 service
    $sb2 = {
        $date = Get-Date -UFormat "%Y%m%d"
        $path = "C:\DR Information"
        if (-not(Test-Path $path)) {New-Item $path -ItemType Directory}
        $fileName = "$path\$date- Config Cache Cleanup.txt"
        Start-Service SPTimerV4
        Get-Service SPTimerV4 | Out-File $fileName -Force -Append
    }
#endregion

#region run first Scriptblock (sb1) on all SharePoint Servers
    foreach ($server in $spServers) {
        $remoteServer = $server.Address.ToString()
        Invoke-Command -ComputerName $remoteServer -ScriptBlock $sb1 -Verbose
    }
#endregion

#region run second Scriptblock (sb2) on all other SharePoint Servers
    foreach ($server in $spServers) {
        $remoteServer = $server.Address.ToString()
        $remoteServer
        if ($remoteServer.ToLower() -ne $thisServer.ToLower()) {
            Invoke-Command -ComputerName $remoteServer -ScriptBlock $sb2 -Verbose
        }
    }
#endregion

#region Start Local Timer Service
    $date = Get-Date -UFormat "%Y%m%d"
    $path = "C:\DR Information"
    $fileName = "$path\$date- Config Cache Cleanup.txt"
    Start-Service SPTimerV4
    Get-Service SPTimerV4 | Out-File $fileName -Force -Append
#endregion