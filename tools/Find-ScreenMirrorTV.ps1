# Windows PowerShell 5.1+. Read-only UPnP discovery; no installation or admin rights.
$ErrorActionPreference = 'Stop'
$locations = @{}
$addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred'
} | Select-Object -ExpandProperty IPAddress -Unique)
if ($addresses.Count -eq 0) { throw 'No active IPv4 network interface. Connect Windows to the same LAN as the TV.' }
foreach ($local in $addresses) {
    Write-Host "Searching from $local ..."
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($local), 0)))
        $udp.Client.ReceiveTimeout = 500
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastTimeToLive, 2)
        $destination = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('239.255.255.250'), 1900)
        foreach ($target in @('urn:schemas-upnp-org:device:MediaRenderer:1', 'ssdp:all')) {
            $message = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: $target`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($message)
            [void]$udp.Send($bytes, $bytes.Length, $destination)
        }
        $until = [DateTime]::UtcNow.AddSeconds(4)
        while ([DateTime]::UtcNow -lt $until) {
            try {
                $sender = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $response = [System.Text.Encoding]::UTF8.GetString($udp.Receive([ref]$sender))
                if ($response -match '(?im)^LOCATION:\s*(https?://[^\r\n]+)') {
                    $url = $Matches[1].Trim()
                    $locations[$url] = $true
                }
            } catch [System.Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::TimedOut) { throw }
            }
        }
    } catch { Write-Warning "Interface $local : $($_.Exception.Message)" }
    finally { if ($null -ne $udp) { $udp.Close() } }
}
$results = @()
foreach ($url in $locations.Keys) {
    try {
        $reply = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.LoadXml($reply.Content)
        $av = $xml.SelectSingleNode("//*[local-name()='service'][contains(*[local-name()='serviceType'], ':AVTransport:')]")
        if ($null -eq $av) { continue }
        $device = $xml.SelectSingleNode("//*[local-name()='device']")
        $nameNode = $device.SelectSingleNode("*[local-name()='friendlyName']")
        $modelNode = $device.SelectSingleNode("*[local-name()='modelName']")
        $name = if ($nameNode) { $nameNode.InnerText } else { '(unnamed)' }
        $model = if ($modelNode) { $modelNode.InnerText } else { '(unknown)' }
        $results += "DEVICE: $name`r`nMODEL: $model`r`nDESCRIPTION URL: $url`r`n"
    } catch { Write-Warning "Could not inspect $url : $($_.Exception.Message)" }
}
Write-Host ''
if ($results.Count -eq 0) {
    Write-Host 'No AVTransport devices found. This does not prove the TV is unsupported.'
    Write-Host 'Check TV power, same LAN, Windows firewall prompt, VPN and router client isolation.'
} else {
    $text = $results -join "`r`n"
    Write-Host $text
    if ($PSScriptRoot) {
        $out = Join-Path $PSScriptRoot 'ScreenMirror-TV-results.txt'
        $text | Set-Content -Path $out -Encoding UTF8
        Write-Host "Results saved: $out"
    }
}
Read-Host 'Press Enter to close'
