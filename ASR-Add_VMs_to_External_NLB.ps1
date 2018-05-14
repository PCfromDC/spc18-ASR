<# 
    .DESCRIPTION 
        This runbook will:
            1) Create a Backend Address Pool for an existing load balancer within the resource group. 
            2) Create a TCP probe for port 443
            3) Attach an existing load balancer to the vNics of all the virtual machines within the resource group. 
            4) Set all NICs to a Static IP Address
            5) Create a NLB Rule to pass port 443 traffi
                
        Pre-requisites 
            All resources involved are based on Azure Resource Manager (NOT Azure Classic)

            - A Load Balancer 
                Frontend should be already configured, this script does not provision the frontend.
            - Resource Group for Load Balancer, Availability Group, VMs
            - The following Variables:
                AzureRunAsAccount 
                        This is the account that has permissions to run the following script in the appropriate Resource Group
                subscriptionName
                        This is the name of the subscription that your AzureRunAsAccount has access to run the Login-AzureRmAccount cmdlet
                           
        How to use this script
            Add this script in the "Add Post Action" in Start Group of the last VM where you need a an external load balancer              
 
    .NOTES 
        Based off script by: krnese@microsoft.com - AzureCAT
        Updated by @PCfromDC 
#> 
param ( 
        [Object]$RecoveryPlanContext 
      ) 

Write-output $RecoveryPlanContext

#region Set Error Preference	
    $ErrorActionPreference = "Stop"
#endregion

#region Determine Failover Direction
    if ($RecoveryPlanContext.FailoverDirection -ne "PrimaryToSecondary") {
        Write-Output "Failover Direction is not Azure, and the script will stop."
        Exit
    }
    else {
        $VMinfo = $RecoveryPlanContext.VmMap | Get-Member | Where-Object MemberType -EQ NoteProperty | select -ExpandProperty Name
        Write-Output ("Found the following VMGuid(s): `n" + $VMInfo)
        if ($VMInfo -is [system.array]) {
            $VMinfo = $VMinfo[0]
            Write-Output "Found multiple VMs in the Recovery Plan"
        }
        else {
            Write-Output "Found only a single VM in the Recovery Plan"
        }
    }
#endregion

#region Log into Azure
    Try {    
        Write-Output "Logging in to Azure..."
        $subscriptionName = Get-AutomationVariable -Name 'subscriptionName'
        $cred = Get-AutomationPSCredential -Name 'AzureRunAsAccount' 
        Add-AzureRmAccount -Credential $cred
        Write-Output "Logged into Azure..."
        Write-Output "Selecting Azure subscription..."
        $subscription = Get-AzureRmSubscription | Where-Object {$_.Name -like "$subscriptionName"}
        $subscription | Set-AzureRmContext
        Write-Output "Subscription Set..."
    }
    Catch {
        $ErrorMessage = 'Login to Azure subscription failed...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
 #endregion

#region Get Resource Group Contents
    Try {
        $vmMap = $RecoveryPlanContext.VmMap
        foreach($VMID in $VMinfo) {
            $vm = $vmMap.$VMID                
                if(-not(($vm -eq $Null) -Or ($vm.ResourceGroupName -eq $Null) -Or ($vm.RoleName -eq $Null))) {
                    Write-output "Resource group name " ($vm.ResourceGroupName)
                    $resourceGroup = $vm.ResourceGroupName.trim()
                    Write-output "Rolename " = $vm.RoleName
            }
        }
        Write-Output "Resource Group: $resourceGroup..."
        $rg = Get-AzureRmResourceGroup -Name $resourceGroup
        $vms = Get-AzureRmVM -ResourceGroupName $rg.ResourceGroupName
        $nlb = Get-AzureRmLoadBalancer -ResourceGroupName $rg.ResourceGroupName
        $NICs = Get-AzureRmNetworkInterface -ResourceGroupName $rg.ResourceGroupName
    }
    Catch {
        $ErrorMessage = 'Failed to retrieve Resource Group information...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Create Backend Address Pool
	$bePoolName = ($nlb.Name + "-be").ToLower()
    $exists = Get-AzureRmLoadBalancerBackendAddressPoolConfig -Name $bePoolName -LoadBalancer $nlb -ErrorAction SilentlyContinue
    if ($exists) {
        Write-Output "Backend Pool already exists..."
        Remove-AzureRmLoadBalancerBackendAddressPoolConfig -Name $bePoolName -LoadBalancer $nlb 
        Start-Sleep -Seconds 10
    }
    $nlb | Add-AzureRmLoadBalancerBackendAddressPoolConfig -Name $bePoolName # Doesn't get created unil running Set-AzureRmLoadBalancer cmdlet
#endregion

#region Create NLB HTTPS Probe
    Try {
        $exists = $nlb | Get-AzureRmLoadBalancerProbeConfig -Name "httpsProbe"
        if (-not($exists)) {
            $nlb | Add-AzureRmLoadBalancerProbeConfig -Name "httpsProbe" -Protocol Tcp -Port 443 -IntervalInSeconds 15 -ProbeCount 2
        }
        $nlb | Set-AzureRmLoadBalancer
    }
    Catch {
        $ErrorMessage = 'Failed to update NLB with Backend and Probe updates...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Get New Backend Pool Information
    Try {
        $backend = Get-AzureRmLoadBalancerBackendAddressPoolConfig -name $bePoolName -LoadBalancer $nlb 
    }
    Catch {
        $ErrorMessage = 'Failed to get backend pool config...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Update NICs on each VM in Resource Group
    Try {
        foreach ($vm in $vms) {
            Write-Output "Getting VM Name..."
            $vmName = $vm.Name
            Write-Output "Getting NIC info..."
            foreach ($nic in $nics) {
                    if ($vm.networkprofile.NetworkInterfaces[0].Id -eq $nic.Id) {
                        Write-Host "Match for $vmName"
                        # Get current IP Address (assigned or static)
                        $currentIP = $nic.IpConfigurations.PrivateIpAddress
                        # Set NIC to Static
                        $nic.IpConfigurations[0].PrivateIpAllocationMethod = "Static"
                        # Assign IP Address
                        $nic.IpConfigurations[0].PrivateIpAddress = $currentIP
                        # Add NIC to NLB Backend
                        $nic.IpConfigurations[0].LoadBalancerBackendAddressPools = $backend
                        # Update NIC
                        $nic | Set-AzureRmNetworkInterface            
                }
            }
        }
    }
    Catch {
        $ErrorMessage = 'Failed to update NIC...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Create NLB Rule for HTTPS Traffic
    Try {
        $nlb = Get-AzureRmLoadBalancer -ResourceGroupName $rg.ResourceGroupName
        $exists = $nlb | Get-AzureRmLoadBalancerRuleConfig -Name "HTTPS"
        if (-not($exists)) {
            $nlb | Add-AzureRmLoadBalancerRuleConfig -Name "HTTPS" `
                    -FrontendIpConfiguration $nlb.FrontendIpConfigurations[0] `
                    -BackendAddressPool $nlb.BackendAddressPools[0] `
                    -Probe $nlb.Probes[0] `
                    -Protocol Tcp `
                    -FrontendPort 443 `
                    -BackendPort 443 `
                    -LoadDistribution SourceIP
        }
        $nlb | Set-AzureRmLoadBalancer
    }
    Catch {
        $ErrorMessage = 'Failed to update NLB with Rule for HTTPS Traffic...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion