

$Params = @{
	"AADTenantId"           = "71adee5d-7b4b-4e47-8814-ade2a984a543"
	"SubscriptionId"        = "15e95d2e-6cd0-4d1c-96da-b8e055a62ee8"
	"UseARMAPI"             = $true
	"ResourceGroupName"     = "mslavdrg"
	"AutomationAccountName" = "mslavdaa1new"
	"Location"              = "chinanorth3"
}

.\CreateOrUpdateAzAutoAccount.ps1 @Params






$AADTenantId = (Get-AzContext).Tenant.Id

$AzSubscription = Get-AzSubscription | Out-GridView -OutputMode:Single -Title "Select your Azure Subscription"
Select-AzSubscription -Subscription $AzSubscription.Id

$ResourceGroup = Get-AzResourceGroup | Out-GridView -OutputMode:Single -Title "Select the resource group for the new Azure Logic App"

$WVDHostPool = Get-AzResource -ResourceType "Microsoft.DesktopVirtualization/hostpools" | Out-GridView -OutputMode:Single -Title "Select the host pool you'd like to scale"

$LogAnalyticsWorkspaceId = Read-Host -Prompt "If you want to use Log Analytics, enter the Log Analytics Workspace ID returned by when you created the Azure Automation account, otherwise leave it blank"
$LogAnalyticsPrimaryKey = Read-Host -Prompt "If you want to use Log Analytics, enter the Log Analytics Primary Key returned by when you created the Azure Automation account, otherwise leave it blank"
$RecurrenceInterval = Read-Host -Prompt "Enter how often you'd like the job to run in minutes, e.g. '15'"
$BeginPeakTime = Read-Host -Prompt "Enter the start time for peak hours in local time, e.g. 9:00"
$EndPeakTime = Read-Host -Prompt "Enter the end time for peak hours in local time, e.g. 18:00"
$TimeDifference = Read-Host -Prompt "Enter the time difference between local time and UTC in hours, e.g. +5:30"
$SessionThresholdPerCPU = Read-Host -Prompt "Enter the maximum number of sessions per CPU that will be used as a threshold to determine when new session host VMs need to be started during peak hours"
$MinimumNumberOfRDSH = Read-Host -Prompt "Enter the minimum number of session host VMs to keep running during off-peak hours"
$MaintenanceTagName = Read-Host -Prompt "Enter the name of the Tag associated with VMs you don't want to be managed by this scaling tool"
$LimitSecondsToForceLogOffUser = Read-Host -Prompt "Enter the number of seconds to wait before automatically signing out users. If set to 0, any session host VM that has user sessions, will be left untouched"
$LogOffMessageTitle = Read-Host -Prompt "Enter the title of the message sent to the user before they are forced to sign out"
$LogOffMessageBody = Read-Host -Prompt "Enter the body of the message sent to the user before they are forced to sign out"

$WebhookURI = Read-Host -Prompt "Enter the webhook URI that has already been generated for this Azure Automation account. The URI is stored as encrypted in the above Automation Account variable. To retrieve the value, see https://learn.microsoft.com/azure/automation/shared-resources/variables?tabs=azure-powershell#powershell-cmdlets-to-access-variables"

$Params = @{
     "AADTenantId"                   = "71adee5d-7b4b-4e47-8814-ade2a984a543"
     "SubscriptionID"                = "15e95d2e-6cd0-4d1c-96da-b8e055a62ee8"
     "ResourceGroupName"             = "mslavdrg"
     "Location"                      = "chinanorth3"
     "UseARMAPI"                     = $true
     "HostPoolName"                  = "mslavdhp1"
     "HostPoolResourceGroupName"     = "mslavdrg"
     "RecurrenceInterval"            = "1"
     "BeginPeakTime"                 = "00:00"
     "EndPeakTime"                   = "23:59"
     "TimeDifference"                = "+8:00"
     "WebhookURI"                    = "https://a8f48ec3-aec5-42de-b320-815ee490b0bb.webhook.cnn3.azure-automation.cn/webhooks?token=IONkEIL2buvBpJO6Uwixzf9DqrbpkUDYw%2fLbrvsvjfA%3d"
}

.\CreateOrUpdateAzLogicApp.ps1 @Params