<# 
    .DESCRIPTION 
        This runbook will:
            1) Start a VM based on $RecoveryPlanContext.FailoverType
                
        Pre-requisites 
            All resources involved are based on Azure Resource Manager (NOT Azure Classic)

            - Parameters set:
				$prodJumpVM for your production jump server
				$asrJumpVM for your test server

            - The following Variables:
                AzureRunAsAccount 
                        This is the account that has permissions to run the following script in the appropriate Resource Group
                subscriptionName
                        This is the name of the subscription that your AzureRunAsAccount has access to run the Login-AzureRmAccount cmdlet
                           
        How to use this script
            Add this script in the "Add Post Action" in Start Group of the last VM where you need a an external load balancer              
 
    .NOTES 
        Script by: @PCfromDC 
#> 
param ( 
        [Object]$RecoveryPlanContext,
        [String]$prodJumpVM = "az-jump-01",
        [String]$asrJumpVM = "asr-jump-01" 
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

 #region Set Recovery Plan Type
    switch ($RecoveryPlanContext.FailoverType) {
        "Test" {$jumpServer = $asrJumpVM}
        default {$jumpServer = $prodJumpVM}
    }
 #endregion

 #region Start Jump Server
    Try {
        Get-AzureRmVM | Where-Object {$_.Name -eq $jumpServer} | Start-AzureRmVM
    }
    Catch {
        $ErrorMessage = "Cannot start Azure Jump VM: $jumpServer..."
        $ErrorMessage += " `n"
        $ErrorMessage += 'Error: '
        $ErrorMessage += $_
        Write-Error -Message $ErrorMessage -ErrorAction Stop
    }
 #endregion