<# 
    .DESCRIPTION 
        This runbook will:
            1) Run a PowerShell Script on an Azure VM in a Resource Group
                
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
        [Object]$RecoveryPlanContext,
        [String]$fileLocation = "https://spc18.blob.core.windows.net/automation/ASR-Update_OS_Cluster_ILB.ps1" 
      ) 

Write-output $RecoveryPlanContext
Write-Output $fileLocation

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
                    Write-output ("Resource group name: " + $vm.ResourceGroupName)
                    $resourceGroup = $vm.ResourceGroupName.trim()
                    Write-output ("Rolename: " + $vm.RoleName)
            }
        }
        Write-Output "Resource Group: $resourceGroup..."
        $vmRG = Get-AzureRmResourceGroup -Name $resourceGroup
        $vms = Get-AzureRmVM -ResourceGroupName $vmRG.ResourceGroupName
        $nlb = Get-AzureRmLoadBalancer -ResourceGroupName $vmRG.ResourceGroupName
        $NICs = Get-AzureRmNetworkInterface -ResourceGroupName $vmRG.ResourceGroupName
        Write-Output "Retreived Resource Group Contents..."
    }
    Catch {
        $ErrorMessage = 'Failed to retrieve Resource Group information...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Get Storage Context
    Try {
        $fileName = $fileLocation.Split("/") | select -Last 1
        $blobContainer = ($fileLocation.Split("/") | select -Last 2) | select -First 1
        $storageAccount = (($fileLocation.Split(".") | select -First 1).Split("/")) | select -Last 1
        $resourceGroup = (Get-AzureRmStorageAccount | Where-Object {$_.StorageAccountName -eq $storageAccount}).ResourceGroupName

        # Get Resource Group
        $rg = Get-AzureRmResourceGroup -Name $resourceGroup

        # Get Storage Account Key
        $srcKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $rg.ResourceGroupName  -Name $storageAccount) | select Value -First 1
        $key = $srcKey.Value

        # Get Storage Context
        $context = New-AzureStorageContext -StorageAccountName $storageAccount -StorageAccountKey $key
        Write-Output "Retreived Storage Context..."
    }
    Catch {
        $ErrorMessage = 'Failed to Get Storage Context...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Get Azure VM and Uninstall CustomScriptExtension
    Try {
        $vm = Get-AzureRmVM -Name $vms[0].Name -ResourceGroupName $vmRG.ResourceGroupName
        $extensions = Get-AzureRmVMExtension -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName -Name CustomScriptExtension -ErrorAction SilentlyContinue
        if ($extensions -ne $null) {
            Write-Output("Extension exists...")
            Write-Output("Deleting Extension....")
            Remove-AzureRmVMCustomScriptExtension -VMName $vm.Name -Name CustomScriptExtension -ResourceGroupName $vm.ResourceGroupName -Force -Confirm:$false
            Write-Output "Uninstalled CustomScriptExtension..."
        }
    }
    Catch {
        $ErrorMessage = 'Failed to Get Azure VM or Remove Custom Script Extension...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion

#region Install CustomScriptExtension and Run Script
    Try{
            $scriptExtenstionName = "Microsoft.PowerShell.Scripts"
            $storageResourceGroup = "SharePoint-ASR"
            $storageAccountName = "spc18"
            $containerName = "automation"
            $fileName = "ASR-Update_OS_Cluster_ILB.ps1"
            $sa = Get-AzureRmStorageAccount -ResourceGroupName $storageResourceGroup -Name $storageAccountName
            $key = ($sa | Get-AzureRmStorageAccountKey) | select Value -First 1

            $vm | Set-AzureRmVMCustomScriptExtension -Name $scriptExtenstionName `
                                             -ResourceGroupName $vm.ResourceGroupName `
                                             -VMName $vm.Name `
                                             -StorageAccountKey $key.Value.ToString() `
                                             -StorageAccountName $storageAccountName `
                                             -ContainerName $containerName `
                                             -FileName $fileName `
                                             -Run $fileName 
                                             # -Argument "-ipAddress $servicesIP"
    }
    Catch {
        $ErrorMessage = 'Failed to Install CustomScriptExtension and Run Script...'
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
#endregion
    