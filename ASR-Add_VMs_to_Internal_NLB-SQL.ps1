<# 
    .DESCRIPTION 
        This runbook will:
            1) Get the settings of the existing NLB
            2) Delete the existing NLB and Create a new one based off the original settings
            3) Create a Backend Address Pool for an existing load balancer within the resource group. 
            4) Create a TCP probe for port 59999
            5) Attach an existing load balancer to the vNics of all the virtual machines within the resource group. 
            6) Set all NICs to a Static IP Address
            7) Create a NLB Rule to pass port 1433 traffic
                
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

#region Get Existing NLB Information and Delete the NLB
    $feConfig = $nlb | Get-AzureRmLoadBalancerFrontendIpConfig
    $nlbName = ($nlb.Name).ToLower()
    $feConfigIp = $feConfig.PrivateIpAddress
    Try {
        Remove-AzureRmLoadBalancer -Name $nlb.Name -ResourceGroupName $rg.ResourceGroupName -Force -Confirm:$false
    }
    Catch {
        $ErrorMessage = 'Failed to Delete NLB...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Create NEW NLB with Information from Deleted NLB
    Try {
        $feName = "$nlbName-fe"
        $beName = "$nlbName-be"
        $NLBvNet = ($nics[0].IpConfigurations.Subnet.Id.Split("/") | Select -Last 3) | Select -First 1
        $NLBsubnet = $nics[0].IpConfigurations.Subnet.Id.Split("/") | select -Last 1
        $vnet = Get-AzureRmVirtualNetwork | Where-Object {$_.Name -eq $NLBvNet} 
        $subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name $NLBsubnet -VirtualNetwork $vnet
        $feIpConfig = New-AzureRmLoadBalancerFrontendIpConfig -Name $feName -PrivateIpAddress $feConfigIp -Subnet $subnet
        $beAddressPool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name $beName
        $hadronProbe = New-AzureRmLoadBalancerProbeConfig -Name "hadronProbe" -Protocol Tcp -Port 59999 -IntervalInSeconds 15 -ProbeCount 2
        $lbrule = New-AzureRmLoadBalancerRuleConfig -Name "SQL" -FrontendIpConfiguration $feIpConfig -BackendAddressPool $beAddressPool -Probe $hadronProbe -Protocol Tcp -FrontendPort 1433 -BackendPort 1433 -LoadDistribution Default -EnableFloatingIP
        $newNLB = New-AzureRmLoadBalancer -ResourceGroupName $rg.ResourceGroupName -Name $nlbName -Location $rg.Location -FrontendIpConfiguration $feIpConfig -LoadBalancingRule $lbrule -BackendAddressPool $beAddressPool -Probe $hadronProbe
    }
    Catch {
        $ErrorMessage = 'Failed to create new NLB...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }

#endregion

#region Get New Backend Pool Information
    Try {
        $backend = Get-AzureRmLoadBalancerBackendAddressPoolConfig -name $beName -LoadBalancer $newNLB 
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