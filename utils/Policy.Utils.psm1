Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/Resource.Utils.psm1" -Force

<#
.SYNOPSIS
Completes a policy compliance scan.

.DESCRIPTION
Starts a policy compliance scan and awaits it's completion. In case of a failure, the policy compliance scan is retried (Default: 3 times).

.PARAMETER ResourceGroup
The resource group to be scanned for policy compliance.

.PARAMETER MaxRetries
The maximum amount of retries in case of failures (Default: 3 times).

.EXAMPLE
$ResourceGroup | Complete-PolicyComplianceScan 
#>
function Complete-PolicyComplianceScan {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup]$ResourceGroup,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 3
    )

    # Policy compliance scan might fail, hence retrying to avoid flaky tests.
    $retries = 0
    do {
        $job = Start-AzPolicyComplianceScan -ResourceGroupName $ResourceGroup.ResourceGroupName -PassThru -AsJob 
        $succeeded = $job | Wait-Job | Receive-Job
        
        if ($succeeded) {
            break
        }
        # Failure: Retry policy compliance scan when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            $retries++
            continue # Not required, just defensive programming.
        }
        # Failure: Policy compliance scan is still failing after maximum retries.
        else {
            throw "Policy compliance scan for resource group '$($ResourceGroup.ResourceId)' failed even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop, just defensive programming.
}

<#
.SYNOPSIS
Completes a policy remediation.

.DESCRIPTION
Starts a remediation for a policy and awaits it's completion. In case of a failure, the policy remediation is retried (Default: 3 times).

.PARAMETER Resource
The resource to be remediated.

.PARAMETER PolicyDefinitionName
The name of the policy definition.

.PARAMETER CheckDeployment
The switch to determine if a deployment is expected. If a deployment is expected but did not happen during policy remediation, the policy remediation is retried.

.PARAMETER MaxRetries
The maximum amount of retries in case of failures (Default: 3 times).

.EXAMPLE
$routeTable | Complete-PolicyRemediation -PolicyDefinition "Modify-RouteTable-NextHopVirtualAppliance" -CheckDeployment
#>
function Complete-PolicyRemediation {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSChildResource]$Resource,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyDefinitionName,
        [Parameter()]
        [switch]$CheckDeployment,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 3
    )
    
    # Get resource group.
    $resourceGroup = Get-ResourceGroup -Resource $Resource
                
    # Get policy assignment.
    $policyAssignment = Get-PolicyAssignment -ResourceGroup $resourceGroup -PolicyDefinitionName $PolicyDefinitionName

    if ($null -eq $policyAssignment) {
        throw "Policy '$($PolicyDefinitionName)' is not assigned to scope '$($resourceGroup.ResourceId)'."
    }

    # Remediation might be started before all previous changes on the resource in scope are completed.
    # This race condition could lead to a successful remediation without any deployment being triggered.
    # When a deployment is expected, it might be required to retry remediation to avoid flaky tests.
    $retries = 0
    do {
        # Trigger and wait for remediation.
        $job = Start-AzPolicyRemediation `
            -Name "$($Resource.Name)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())" `
            -Scope $Resource.Id `
            -PolicyAssignmentId $policyAssignment.PolicyAssignmentId `
            -ResourceDiscoveryMode ReEvaluateCompliance `
            -AsJob
        $remediation = $job | Wait-Job | Receive-Job
        
        # Check remediation provisioning state and deployment when required .
        if ($remediation.ProvisioningState -eq "Succeeded") {
            if ($CheckDeployment) {
                $deployed = $remediation.DeploymentSummary.TotalDeployments -gt 0
                
                # Success: Deployment was triggered.
                if ($deployed) {
                    break 
                }
                # Failure: No deployment was triggered, so retry when still below maximum retries.
                elseif ($retries -le $MaxRetries) {
                    $retries++
                    continue # Not required, just defensive programming.
                }
                # Failure: No deployment was triggered even after maximum retries.
                else {
                    throw "Policy '$($PolicyDefinitionName)' succeeded to remediated resource '$($Resource.Id)', but no deployment was triggered even after $($MaxRetries) retries."
                }
            }
            # Success: No deployment need to checked, hence no retry required.
            else {
                break
            }
        }
        # Failure: Remediation failed, so retry when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            $retries++
            continue # Not required, just defensive programming.
        }
        # Failure: Remediation failed even after maximum retries.
        else {
            throw "Policy '$($PolicyDefinitionName)' failed to remediate resource '$($Resource.Id)' even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop, just defensive programming.
}

function Get-PolicyAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup]$ResourceGroup,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyDefinitionName
    )

    # Get policy assignment.
    $policyAssignment = Get-AzPolicyAssignment -Scope $ResourceGroup.ResourceId
    | Select-Object -Property * -ExpandProperty Properties 
    | Where-Object { 
        # Only policies directly assigned to resource group (not inherited).
        $_.Scope -eq $ResourceGroup.ResourceId -and
        $_.PolicyDefinitionId.EndsWith($PolicyDefinitionName) 
    } 
    | Select-Object -First 1

    return $policyAssignment
}

<#
.SYNOPSIS
Gets the policy compliance state of a resource.

.DESCRIPTION
Gets the policy compliance state of a resource. In case of a failure, getting the policy compliance state is retried (Default: 30 times) after a few seconds of waiting (Default: 60s).

.PARAMETER Resource
The resource to get the policy compliance state for. 

.PARAMETER PolicyDefinitionName
The name of the policy definition.

.PARAMETER WaitSeconds
The duration in seconds to wait between retries in case of failures (Default: 60s).

.PARAMETER MaxRetries
The maximum amount of retries in case of failures (Default: 3 times).

.EXAMPLE
$networkSecurityGroup | Get-PolicyComplianceState -PolicyDefinition "OP-Audit-NSGAny" | Should -BeFalse
#>
function Get-PolicyComplianceState {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSChildResource]$Resource,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyDefinitionName,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$WaitSeconds = 60,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 30
    )

    # Policy compliance scan might be completed, but policy compliance state might still be null due to race conditions.
    # Hence waiting a few seconds and retrying to get the policy compliance state to avoid flaky tests.
    $retries = 0
    do {
        # Get resource group.
        $resourceGroup = Get-ResourceGroup -Resource $Resource
                
        # Get policy assignment.
        $policyAssignment = Get-PolicyAssignment -ResourceGroup $resourceGroup -PolicyDefinitionName $PolicyDefinitionName

        if ($null -eq $policyAssignment) {
            throw "Policy '$($PolicyDefinitionName)' is not assigned to scope '$($resourceGroup.ResourceId)'."
        }

        # Get policy state
        $policyState = Get-AzPolicyState `
            -ResourceGroupName  $resourceGroup.ResourceGroupName `
            -PolicyAssignmentName $policyAssignment.Name `
            -Filter "ResourceId eq '$($Resource.Id)'"

        # Success: Policy compliance state is not null.
        if ($null -ne $policyState.IsCompliant) {
            break
        }
        # Failure: Policy compliance state is null, so wait a few seconds and retry when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            Start-Sleep -Seconds $WaitSeconds
            $retries++
            continue # Not required, just defensive programming.
        }
        # Failure: Policy compliance state still null after maximum retries.
        else {
            throw "Policy '$($PolicyDefinitionName)' completed compliance scan for resource '$($Resource.Id)', but policy compliance state is null even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop, just defensive programming.

    return $policyState.IsCompliant
}

function New-PolicyAssignment {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup]$ResourceGroup,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyDefinitionName,
        [Parameter()]
        [ValidateNotNull()]
        [Hashtable] $PolicyParameterObject = @{},
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$WaitSeconds = 30,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 10
    )

    # Get policy definition.
    $policyDefinition = Get-AzPolicyDefinition -Name $PolicyDefinitionName

    if ($null -eq $policyDefinition) {
        throw "Policy '$($PolicyDefinitionName)' is not defined at scope '/subscriptions/$((Get-AzContext).Subscription.Id)'."
    }

    # Assign policy to resource group.
    # 'DeployIfNotExists' and 'Modify' policies require a managed identity with the appropriated roles for remediation.
    if ($policyDefinition.Properties.PolicyRule.Then.Effect -in "DeployIfNotExists", "Modify") {
        # Create policy assignment and managed identity.
        $policyAssignment = New-AzPolicyAssignment `
            -Name $PolicyDefinitionName `
            -DisplayName $PolicyDefinitionName `
            -PolicyDefinition $policyDefinition `
            -PolicyParameterObject $PolicyParameterObject `
            -Scope $ResourceGroup.ResourceId `
            -Location $ResourceGroup.Location `
            -AssignIdentity

        # Assign appropriated roles to managed identity by by directly invoking the Azure REST API.
        # Using 'New-AzRoleAssignment' would require higher privileges to query Azure Active Directoy.
        # See also: https://github.com/Azure/azure-powershell/issues/10550#issuecomment-784215221
        $roleDefinitionIds = $policyDefinition.Properties.PolicyRule.Then.Details.RoleDefinitionIds
        foreach ($roleDefinitionId in $roleDefinitionIds) {
            # Policy compliance scan might be completed, but policy compliance state might still be null due to race conditions.
            # Hence waiting a few seconds and retrying to get the policy compliance state to avoid flaky tests.
            $retries = 0
            do {
                # Wait for Azure Active Directory to replicate managed identity.
                Start-Sleep -Seconds $WaitSeconds

                $payload = [PSCustomObject]@{ 
                    properties = [PSCustomObject]@{ 
                        roleDefinitionId = $roleDefinitionId
                        principalId      = $policyAssignment.Identity.PrincipalId
                    }
                } | ConvertTo-Json

                $httpResponse = Invoke-AzRestMethod `
                    -ResourceGroupName $ResourceGroup.ResourceGroupName `
                    -ResourceProviderName "Microsoft.Authorization" `
                    -ResourceType "roleAssignments" `
                    -Name (New-Guid).Guid `
                    -ApiVersion "2015-07-01" `
                    -Method "PUT" `
                    -Payload $payload

                # Created - Returns information about the role assignment.
                if ($httpResponse.StatusCode -eq 201) {
                    break
                }
                # Azure Active Directory did not yet complete replicating the managed identity.
                elseif (
                    ($httpResponse.StatusCode -eq 400) -and 
                    ($httpResponse.Content -like "*PrincipalNotFound*") -and
                    ($retries -le $MaxRetries)
                ) {
                    $retries++
                    continue # Not required, just defensive programming.
                }
                # Error response describing why the operation failed.
                else {
                    throw "Operation failed with message: '$($httpResponse.Content)'"
                }
            } while ($retries -le $MaxRetries)
        }
    }
    else {
        # Create policy assignment.
        New-AzPolicyAssignment `
            -Name $PolicyDefinitionName `
            -PolicyDefinition $policyDefinition `
            -PolicyParameterObject $PolicyParameterObject `
            -Scope $ResourceGroup.ResourceId
    }
}