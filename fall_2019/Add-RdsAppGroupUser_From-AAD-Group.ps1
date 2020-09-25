Param
(
  [Parameter (Mandatory= $true)]
  [String] $HostPoolName
 ,[Parameter (Mandatory= $true)]
  [String] $AADGroup
 ,[Parameter (Mandatory= $false)]
  [bool] $ReportOnly
)


### Function for returning timestamp
Function Get-Timestamp {
    $tDate =(Get-Date).ToUniversalTime()
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")
    $tCurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tDate, $tz)
    #Formatted GMT timestamp for use in logging/display
    return (Get-Date -Date $tCurrentTime -format "yyyy-MM-dd HH:mm:ss").ToString()
}


### Connect to Azure using Automation Account's RunAs SP
Disable-AzContextAutosave –Scope Process # Ensures you do not inherit an AzContext in your runbook
$connection = Get-AutomationConnection -Name "AzureRunAsConnection"
# Wrap authentication in retry logic for transient network failures
$logonAttempt = 0
while(!($connectionResult) -and ($logonAttempt -le 10))
{
    $LogonAttempt++
    # Logging in to Azure...
    $connectionResult = Connect-AzAccount `
                            -ServicePrincipal `
                            -Tenant $connection.TenantID `
                            -ApplicationId $connection.ApplicationID `
                            -CertificateThumbprint $connection.CertificateThumbprint

    Start-Sleep -Seconds 10
}
#$AzureContext = Get-AzSubscription -SubscriptionId $connection.SubscriptionID


### Connect to AAD
Connect-AzureAD `
    -TenantId $connection.TenantID `
    -ApplicationId $connection.ApplicationId `
    -CertificateThumbprint $connection.CertificateThumbprint 


### Connect to WVD
#Import Credential objects from the Automation Account
$WVDCred = Get-AutomationPSCredential -Name "Windows Virtual Desktop Svc Principal"
$RdsAccount = Add-RdsAccount  `
 -DeploymentUrl "https://rdbroker.wvd.microsoft.com" `
 -Credential $WVDCred `
 -ServicePrincipal `
 -AadTenantId $connection.TenantId


#############################################################################################################
### Setup variables
#############################################################################################################

### Storage 
$RG = "<your-resourcegroup>"
$StorageAccount = "<yourstorageaccount>"
$Container = "monitoring"
$fileLog = "WVD_AddUsersToPool_$HostPoolName" + "_$AADGroup.csv"

### WVD
$TenantName = "<yourWVDtenant>"
$AppGroupName = "Desktop Application Group"

### Execution timestamp
$Timestamp = Get-Timestamp
Write-Output "-------------------------------------------------------------------------------------------------------------------"
Write-Output "$Timestamp Beginning script execution"
If ($ReportOnly) {
    Write-Output "*** Report Only mode is set, no changes will be applied or logged ***"
}

#############################################################################################################
### Access storage account
#############################################################################################################
#Get key to storage account
$acctKey = (Get-AzStorageAccountKey -Name $StorageAccount -ResourceGroupName $RG).Value[0]
#Map to the reports BLOB context
$storageContext = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $acctKey
#Download files from the storage account to local Azure Automation
Write-Output "-------------------------------------------------------------------------------------------------------------------"
$curTime = Get-Timestamp
Write-Output "$curTime Downloading file from storage account: $StorageAccount, container: $Container"
Get-AzStorageBlobContent -Blob $fileLog -Container $Container -Context $storageContext -Verbose


#############################################################################################################
### AAD and WVD section
#############################################################################################################

#Get from AAD
$AADGroupObj = Get-AzureADGroup -Filter "DisplayName eq '$AADGroup'"
$AADGroupID = $AADGroupObj.ObjectId
#$AADGroup | fl
Write-Output "-------------------------------------------------------------------------------------------------------------------"
$curTime = Get-Timestamp
Write-Output "$curTime Retrieving members of AAD group $AADGroup"
#$AADGroupMembers = Get-AzureADGroupMember -ObjectId $AADGroupID -Top 99999 #| select-object UserPrincipalName
#$AADGroupMembers = $AADGroupMembers | Sort-Object -Property UserPrincipalName
#$AADGroupMemberObjects = Get-AzureADGroupMember -ObjectId $AADGroupID -All $true | Sort-Object -Property ObjectType -Descending
$AADGroupMemberObjects = Get-AzureADGroupMember -ObjectId $AADGroupID -All $true | Select-Object UserPrincipalName, ObjectId, ObjectType, DisplayName, AccountEnabled, AssignedLicenses
$AADGroupMemberObjects = $AADGroupMemberObjects | Sort-Object -Property ObjectType -Descending #Get users before groups

$AADGroupMembers = @()
$AADGroupMembers
ForEach ($AADObj in $AADGroupMemberObjects) {
	If ($AADObj.ObjectType -eq "User") {
		#Adding direct user to array
		$AADGroupMembers += $AADObj
	} ElseIf ($AADObj.ObjectType -eq "Group" -and $AADObj.DisplayName -ne "<undesirableGroup>") {
        $grp = $AADObj.DisplayName
		Write-Output "Getting members of subgroup $grp"
		$subgroup = Get-AzureADGroupMember -ObjectId $AADObj.ObjectId -All $true | Select-Object UserPrincipalName, ObjectId, ObjectType, DisplayName, AccountEnabled, AssignedLicenses
		ForEach ($obj in $subgroup) {
			If ($obj.ObjectType -eq "User") {
				#Adding nested L1 user to array
				$AADGroupMembers += $obj
			}
		}
	}
}
#Display
$count = $AADGroupMembers.Length
$curTime = Get-Timestamp
Write-Output "$curTime Found a total of $count members of AAD group $AADGroup"


#Get from WVD
$curTime = Get-Timestamp
Write-Output "$curTime Retrieving members of WVD hostpool $HostPoolName"
$RdsAppGroupUsers = Get-RdsAppGroupUser -TenantName $TenantName -HostPoolName $HostPoolName -AppGroupName $AppGroupName | Select-Object UserPrincipalName
#Display 
$count = $RdsAppGroupUsers.Length
$curTime = Get-Timestamp
Write-Output "$curTime Found $count members of WVD hostpool $HostPoolName"

#Create logging array
$LogOut= @() 

#Loop through AD group members, comparing with WVD AppGroup to check for missing members
$curTime = Get-Timestamp
write-output "$curTime Starting loop to identify users missing from hostpool $HostPoolName"
Write-Output "-------------------------------------------------------------------------------------------------------------------"
$i=0
ForEach ($AADUser in $AADGroupMembers) {

	#Exclude user accounts with no UPN, i.e. groups and contacts
	If ($AADUser.UserPrincipalName) {
		$AADUPN = $AADUser.UserPrincipalName.ToLower()
        #$AADAccount = Get-AzureADUser -ObjectId $AADUPN ###Not needed because AccountEnabled and AssignedLicenses are part of $AADGroupMembers

        #Exclude any disabled user accounts, and those without licenses
		If ( $AADUser.AccountEnabled -eq $True -and $AADUser.AssignedLicenses ){
            
            #Check whether AD user is missing from RDS AppGroup
		    If ( !($RdsAppGroupUsers.UserPrincipalName.ToLower().Contains($AADUPN)) ){
            
                #Increment loop counter
                $i+=1
                #Append to log array
                $LogOut+= @{
                    _ExecutionTimestamp = $Timestamp ;
                    ADGroup = $AADGroup ;
                    HostPool = $HostPoolName ;
                    LoopCount = $i ;
                    UPN = $AADUPN
                }

                If ($ReportOnly) {
                    Write-Output "$i : Found missing user $AADUPN"
                } Else {
                    Write-Output "$i : Adding missing user $AADUPN"
                    #Add-RdsAppGroupUser -TenantName $TenantName -HostPoolName $HostPoolName -AppGroupName $AppGroupName -UserPrincipalName $AADUPN
                    Try { 
                        Add-RdsAppGroupUser -TenantName $TenantName -HostPoolName $HostPoolName -AppGroupName $AppGroupName -UserPrincipalName $AADUPN
                    }
                    Catch {
                        Write-Host "An error occurred:"
                        Write-Host $_.Exception
                        
                        Write-Host "Attempting to re-authenticate to RDInfra management"
                        Add-RdsAccount  `
                            -DeploymentUrl "https://rdbroker.wvd.microsoft.com" `
                            -Credential $WVDCred `
                            -ServicePrincipal `
                            -AadTenantId $connection.TenantId
                        Add-RdsAppGroupUser -TenantName $TenantName -HostPoolName $HostPoolName -AppGroupName $AppGroupName -UserPrincipalName $AADUPN
                    }
                }
			}
		}
	}
}
Write-Output "$i missing users found"


        
#Export log to CSV
#$LogOut | % { new-object PSObject -Property $_} | ft
$LogOut | % { new-object PSObject -Property $_} | Export-Csv -Path $fileLog -NoTypeInformation -Append


### Copy the updated files from local Azure Automation back to the storage account
Write-Output "-------------------------------------------------------------------------------------------------------------------"
$curTime = Get-Timestamp
If ($ReportOnly) {
    Write-Output "$curTime Report only mode was set, exiting without uploading logfile"
} Else {
    Write-Output "$curTime Uploading updated logfile $fileLog to storage account: $StorageAccount, container: $Container"
    Set-AzStorageBlobContent -File $fileLog -Container $Container -BlobType Block -Context $storageContext -Verbose -Force
}
