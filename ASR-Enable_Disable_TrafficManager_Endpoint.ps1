<# 
    .DESCRIPTION 
        This runbook will:
            1) Disable a traffic manager endpoint on test failovers
            2) Enable a traffic manager endpoint on cleanup
                
        Pre-requisites 
            All resources involved are based on Azure Resource Manager (NOT Azure Classic)

            - A Traffic Manager
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

 #region Function Enable-AzureRmTrafficManagerEndpoint
    function enable-azTmEndpoint {
        Try {
            Enable-AzureRmTrafficManagerEndpoint -Name "spc18-vip.pcDemo.net" -ProfileName "spc18" -ResourceGroupName SharePoint-ASR -Type ExternalEndpoints -Force
        }
        Catch {
            $ErrorMessage = 'Enable-AzureRmTrafficManagerEndpoint failed...'
            $ErrorMessage += " `n"
            $ErrorMessage += 'Error: '
            $ErrorMessage += $_
            Write-Error -Message $ErrorMessage -ErrorAction Stop
        }
    }

 #endregion

 #region Function Disable-AzureRmTrafficManagerEndpoint
    function disable-azTmEndpoint {
        Try {
            Disable-AzureRmTrafficManagerEndpoint -Name "spc18-vip.pcDemo.net" -ProfileName "spc18" -ResourceGroupName SharePoint-ASR -Type ExternalEndpoints -Force
        }
        Catch {
            $ErrorMessage = 'Disable-AzureRmTrafficManagerEndpoint failed...'
            $ErrorMessage += " `n"
            $ErrorMessage += 'Error: '
            $ErrorMessage += $_
            Write-Error -Message $ErrorMessage -ErrorAction Stop
        }
    }
 #endregion

 #region Set Recovery Plan Type
    if ($RecoveryPlanContext -eq "cleanup") {
        enable-azTmEndpoint
    }
    else {
        switch ($RecoveryPlanContext.FailoverType) {
            "Test" {disable-azTmEndpoint}
            default {Write-Output "Not test or cleanup failover type, AzureRmTrafficManagerEndpoint has not been touched..."}
        }
    }
 #endregion