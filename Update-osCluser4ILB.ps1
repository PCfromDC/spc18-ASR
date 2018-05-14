$ilbName = "Azure ILB"
$ilbAddress = "192.168.10.86"
$ilbSubnetMask = "255.255.255.240"
$ClusterNetworkName = (Get-ClusterNetwork).Name

# Create IP Address in AG Cluster
$resourceGroup = Get-ClusterResource | Where-Object {$_.ResourceType -eq "SQL Server Availability Group"}
Add-ClusterResource -Name $ilbName -ResourceType "IP Address" -Group $resourceGroup

# Set Properties to Azure ILB Resource
$resource = Get-ClusterResource -Name $ilbName
$resource | Set-ClusterParameter -Multiple @{"Address"="$ilbAddress";"SubnetMask"="$ilbSubnetMask";"Network"="$ClusterNetworkName";"EnableDhcp"=0}

# Set Dependencies for IP Addresses
$agName = $resourceGroup.Name
$networkName = Get-ClusterResource | Where-Object {($_.OwnerGroup -eq $agName) -and ($_.ResourceType -eq "Network Name")}
$networkIpName = (Get-ClusterResource | Where-Object {($_.Name -like "$agName*") -and ($_.OwnerGroup -eq $agName) -and ($_.ResourceType -eq "IP Address")}).Name
$networkName | Set-ClusterResourceDependency -Dependency "[$networkIpName] or [$ilbName]"

# Set Cluster Resource for Azure ILB
Get-ClusterResource $ilbName | Set-ClusterParameter -Multiple @{"Address"="$ilbAddress";"ProbePort"="59999";"SubnetMask"="255.255.255.255";"Network"="$ClusterNetworkName";"OverrideAddressMatch"=1;"EnableDhcp"=0}

# Start Cluster Resource
$resource = Get-ClusterResource -Name $ilbName
$resource | Start-ClusterResource

# Flush DNS
ipconfig /flushdns