Import-Module -Name Az.Resources
. "$($PSScriptRoot)/TestContext.ps1"

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
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSObject] $TestContext,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 3
    )

    # Policy compliance scan might fail, hence retrying to avoid flaky tests.
    $retries = 0
    while ($retries -le $MaxRetries) {
        # Trigger policy compliance scan and wait for its completion.
        $job = Start-AzPolicyComplianceScan -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName -PassThru -AsJob 
        $succeeded = $job | Wait-Job | Receive-Job
        
        if ($succeeded) {
            break
        }

        $retries++
    } 

    if ($retries -gt $MaxRetries) {
        throw "Policy compliance scan for resource group '$($TestContext.ResourceGroup.ResourceId)' failed even after $($MaxRetries) retries."
    }
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
        [ValidateNotNull()]
        [PSObject] $TestContext,
        [Parameter()]
        [switch]$CheckDeployment,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 3
    )
    
    # Remediation might be started before all previous changes on the resource in scope are completed.
    # This race condition could lead to a successful remediation without any deployment being triggered.
    # When a deployment is expected, it might be required to retry remediation to avoid flaky tests.
    $retries = 0
    while ($retries -le $MaxRetries) {
        # Trigger remediation and wait for its completion.
        $job = Start-AzPolicyRemediation `
            -Name "$($Resource.Name)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())" `
            -Scope $Resource.Id `
            -PolicyAssignmentId $TestContext.PolicyAssignment.PolicyAssignmentId `
            -ResourceDiscoveryMode ReEvaluateCompliance `
            -AsJob
        $remediation = $job | Wait-Job | Receive-Job

        # Remediation was successful.
        if ($remediation.ProvisioningState -eq "Succeeded") {
            # No deployment is expected.
            if (-not $CheckDeployment) {
                break
            }
            # Deployment is expected and was successfully executed.
            elseif ($remediation.DeploymentSummary.TotalDeployments -gt 0) {
                break
            }
        }

        $retries++
    } 

    if ($retries -gt $MaxRetries) {
        throw "Policy '$($TestContext.Policy)' failed to remediate resource '$($Resource.Id)' even after $($MaxRetries) retries."
    }
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
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSChildResource]$Resource,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSObject] $TestContext,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$WaitSeconds = 30,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 60
    )

    # Policy compliance scan might be completed, but policy compliance state might still be null due to race conditions.
    # Hence waiting a few seconds and retrying to get the policy compliance state to avoid flaky tests.
    $retries = 0
    while ($retries -le $MaxRetries) {
        # Wait for policy compliance state to be propagated.
        Start-Sleep -Seconds $WaitSeconds

        # Get policy state
        $policyState = Get-AzPolicyState `
            -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
            -PolicyAssignmentName $TestContext.PolicyAssignment.Name `
            -Filter "ResourceId eq '$($Resource.Id)'"

        # Return policy compliance state, which can be either compliant or non compliant.
        if ($policyState.ComplianceState -in "Compliant", "NonCompliant") {
            return $policyState.ComplianceState -eq "Compliant"
        }
        
        $retries++
    } 

    if ($retries -gt $MaxRetries) {
        throw "Policy '$($TestContext.PolicyDefinition.Name)' completed compliance scan for resource '$($Resource.Id)', but policy compliance state could not be determined even after $($MaxRetries) retries."
    }
}

function New-PolicyAssignment {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSObject] $TestContext,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$WaitSeconds = 30,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 10
    )

    # Assign policy to resource group.
    # 'DeployIfNotExists' and 'Modify' policies require a managed identity with the appropriated roles for remediation.
    if ($TestContext.PolicyDefinition.Properties.PolicyRule.Then.Effect -in "DeployIfNotExists", "Modify") {
        # Create policy assignment and managed identity.
        $policyAssignment = New-AzPolicyAssignment `
            -Name $TestContext.Id `
            -PolicyDefinition $TestContext.PolicyDefinition `
            -PolicyParameterObject $TestContext.PolicyParameterObject `
            -Scope $TestContext.ResourceGroup.ResourceId `
            -Location $TestContext.ResourceGroup.Location `
            -AssignIdentity

        # Assign appropriated roles to managed identity by directly invoking the Azure REST API.
        # Using 'New-AzRoleAssignment' would require higher privileges to query Azure Active Directoy.
        # See also: https://github.com/Azure/azure-powershell/issues/10550#issuecomment-784215221
        $roleDefinitionIds = $TestContext.PolicyDefinition.Properties.PolicyRule.Then.Details.RoleDefinitionIds
        foreach ($roleDefinitionId in $roleDefinitionIds) {
            # Managed identity might not be created yet.
            # Hence waiting a few seconds and retrying role assignment to avoid flaky tests.
            $retries = 0
            while ($retries -le $MaxRetries) {
                # Wait for Azure Active Directory to replicate managed identity.
                Start-Sleep -Seconds $WaitSeconds

                $payload = [PSCustomObject]@{ 
                    properties = [PSCustomObject]@{ 
                        roleDefinitionId = $roleDefinitionId
                        principalId      = $policyAssignment.Identity.PrincipalId
                    }
                } | ConvertTo-Json

                $httpResponse = Invoke-AzRestMethod `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -ResourceProviderName "Microsoft.Authorization" `
                    -ResourceType "roleAssignments" `
                    -Name $TestContext.Id `
                    -ApiVersion "2015-07-01" `
                    -Method "PUT" `
                    -Payload $payload
                
                # Azure Active Directory did not yet complete replicating the managed identity.
                if (
                    ($httpResponse.StatusCode -eq 400) -and 
                    ($httpResponse.Content -like "*PrincipalNotFound*")
                ) {
                    $retries++
                    continue # Not required, just defensive programming.
                }
                # Role assignment was successfully created.
                elseif ($httpResponse.StatusCode -eq 201) {
                    break
                }
                # Role assignment failed.
                else {
                    throw "Policy '$($testContext.Policy)' was assigned to scope '$($TestContext.ResourceGroup.ResourceId)', but assinging role '$($roleDefinitionId)' to its managed identity '$($policyAssignment.Identity.PrincipalId)' failed with message: '$($httpResponse.Content)'."
                }
            } 

            if ($retries -gt $MaxRetries) {
                throw "Policy '$($testContext.Policy)' was assigned to scope '$($TestContext.ResourceGroup.ResourceId)', but assinging role '$($roleDefinitionId)' to its managed identity '$($policyAssignment.Identity.PrincipalId)' failed even after $($MaxRetries) retries."
            }
        }
    }
    else {
        # Create policy assignment.
        $policyAssignment = New-AzPolicyAssignment `
            -Name $TestContext.Id `
            -PolicyDefinition $TestContext.PolicyDefinition `
            -PolicyParameterObject $TestContext.PolicyParameterObject `
            -Scope $TestContext.ResourceGroup.ResourceId
    }

    # Re-login to make sure the policy assignment is applied.
    Connect-Account

    return $policyAssignment
}

function New-PolicyDefinition {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSObject] $TestContext,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$WaitSeconds = 10,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 5
    )

    # The maximum depth allowed for serialization is 100.
    $depth = 100 
    
    # Deserialize the policy file.
    $policy = Get-Content -Path $TestContext.PolicyFile -Raw | ConvertFrom-Json -Depth $depth
    
    # Replace name of the policy definition.
    $policy.name = "$((New-Guid).Guid)"
    
    # Replace id of the policy definition.
    $policy.id = "/subscriptions/$($TestContext.Subscription.Id)/providers/Microsoft.Authorization/policyDefinitions/$($policyDefinition.name)"

    # Create policy definition at subscription scope.
    $payload = $policy | ConvertTo-Json -Depth $depth
    $httpResponse = Invoke-AzRestMethod `
        -SubscriptionId $TestContext.Subscription.Id `
        -ResourceProviderName "Microsoft.Authorization" `
        -ResourceType "policyDefinitions" `
        -Name $policy.name `
        -ApiVersion "2020-09-01" `
        -Method "PUT" `
        -Payload $payload
                
    # Creating policy definition failed.
    if ($httpResponse.StatusCode -ne 201) {
        throw "Policy '$($testContext.Policy)' could not be defined at scope '/subscriptions/$($TestContext.Subscription.Id)' and failed with message: '$($httpResponse.Content)'."
    }
    
    # Re-login to make sure policy definition is applied.
    Connect-Account

    # Policy definition still might not be applied yet.
    # Hence waiting a few seconds and retrying to avoid flaky tests.
    $retries = 0
    while ($retries -le $MaxRetries) {
        try {
            # Wait for policy definition to be propagated.
            Start-Sleep -Seconds $WaitSeconds

            $policyDefinition = Get-AzPolicyDefinition `
                -Name $policy.name `
                -ErrorAction Stop # Otherwise no exception would be thrown, since $ErrorActionPreference defaults to 'Continue' in PowerShell.

            if ($null -ne $policyDefinition) {
                return $policyDefinition
            }
        }
        catch {
            # Do nothing, just retry.
        }

        $retries++
    } 

    if ($retries -gt $MaxRetries) {
        throw "Policy '$($testContext.Policy)' was defined at scope '/subscriptions/$($TestContext.Subscription.Id)', but policy definition '$($policy.name)' was still not found even after $($MaxRetries) retries."
    }
}

function Connect-Account {
    $context = Get-AzContext
    
    if ($context.Account.Type -ne "ServicePrincipal") {
        throw "Re-login requires using a service principal."
    }

    $password = ConvertTo-SecureString $context.Account.ExtendedProperties.ServicePrincipalSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($context.Account.Id, $password)
    Connect-AzAccount `
        -Tenant $context.Tenant.Id `
        -Subscription $context.Subscription.Id `
        -Credential $credential `
        -ServicePrincipal `
        -Scope Process `
        > $null
}