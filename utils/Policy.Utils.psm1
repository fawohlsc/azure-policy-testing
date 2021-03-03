Import-Module -Name Az.Resources

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
    do {
        $job = Start-AzPolicyComplianceScan -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName -PassThru -AsJob 
        $succeeded = $job | Wait-Job | Receive-Job
        
        if ($succeeded) {
            break
        }
        # Failure: Retry policy compliance scan when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            $retries++
        }
        # Failure: Policy compliance scan is still failing after maximum retries.
        else {
            throw "Policy compliance scan for resource group '$($TestContext.ResourceGroup.ResourceId)' failed even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop.
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
    do {
        # Trigger and wait for remediation.
        $job = Start-AzPolicyRemediation `
            -Name "$($Resource.Name)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())" `
            -Scope $Resource.Id `
            -PolicyAssignmentId $TestContext.PolicyAssignment.PolicyAssignmentId `
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
                }
                # Failure: No deployment was triggered even after maximum retries.
                else {
                    throw "Policy '$($TestContext.Policy)' succeeded to remediated resource '$($Resource.Id)', but no deployment was triggered even after $($MaxRetries) retries."
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
        }
        # Failure: Remediation failed even after maximum retries.
        else {
            throw "Policy '$($TestContext.Policy)' failed to remediate resource '$($Resource.Id)' even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop.
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
        [ushort]$WaitSeconds = 60,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 30
    )

    # Policy compliance scan might be completed, but policy compliance state might still be null due to race conditions.
    # Hence waiting a few seconds and retrying to get the policy compliance state to avoid flaky tests.
    $retries = 0
    do {
        # Get policy state
        $policyState = Get-AzPolicyState `
            -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
            -PolicyAssignmentName $TestContext.PolicyAssignment.Name `
            -Filter "ResourceId eq '$($Resource.Id)'"

        # Success: Policy compliance state is either compliant or non-compliant
        if ($policyState.ComplianceState -in "Compliant", "NonCompliant") {
            return $policyState.ComplianceState -eq "Compliant"
        }
        # Failure: Policy compliance state is null, so wait a few seconds and retry when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            Start-Sleep -Seconds $WaitSeconds
            $retries++
        }
        # Failure: Policy compliance state still null after maximum retries.
        else {
            throw "Policy '$($TestContext.PolicyDefinition.Name)' completed compliance scan for resource '$($Resource.Id)', but policy compliance state is null even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop.
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

                # Role assignment was successfully created.
                if ($httpResponse.StatusCode -eq 201) {
                    break
                }
                # Azure Active Directory did not yet complete replicating the managed identity.
                elseif (
                    ($httpResponse.StatusCode -eq 400) -and 
                    ($httpResponse.Content -like "*PrincipalNotFound*")
                ) {
                    $retries++
                    continue # Not required, just defensive programming.
                }
                # Error response describing why the operation failed.
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
    
    # Deserialize the template file.
    $template = Get-Content -Path $TestContext.PolicyTemplateFile -Raw | ConvertFrom-Json -Depth $depth
    
    # Change template schema to subscription deployment template.
    $template.'$schema' = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"

    # Search for policy definition.
    $policyDefinitionResource = $template.resources 
    | Where-Object { $_.type -eq "Microsoft.Authorization/policyDefinitions" } 
    | Select-Object -Last 1

    if (-not $policyDefinitionResource) {
        throw "Policy template file '$($TestContext.PolicyTemplateFile)' does not contain policy definition resource."
    }

    # Replace name of the policy definition.
    $policyDefinitionResource.name = "$((New-Guid).Guid)"
    
    # Replace display name of the policy definition.
    if ($policyDefinitionResource.properties.displayname) {
        $policyDefinitionResource.properties.displayname = $policyDefinitionResource.name
    }

    # Create temporary policy template file.
    $templateFile = New-TemporaryFile
    try {
        # Serialize to temporary policy template file.
        $template | ConvertTo-Json -Depth $depth | Out-File $templateFile.FullName
    
        # Deploy temporary policy template file at subscription scope.
        $job = New-AzDeployment -templateFile $templateFile -Location $TestContext.Location -AsJob
        $deployment = $job | Wait-Job | Receive-Job

        if ($deployment.ProvisioningState -ne "Succeeded") {
            throw "Policy template file '$($TestContext.PolicyTemplateFile)' failed during deployment."
        }
    }
    finally {
        Remove-Item $templateFile -Force
    }

    # Re-login to make sure policy definition is applied.
    Connect-Account

    # Policy definition still might not be applied yet.
    # Hence waiting a few seconds and retrying to avoid flaky tests.
    $retries = 0
    while ($retries -le $MaxRetries) {
        try {
            # Wait for policy definition to be applied.
            Start-Sleep -Seconds $WaitSeconds

            $policyDefinition = Get-AzPolicyDefinition `
                -Name $policyDefinitionResource.Name `
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
        throw "Policy template file '$($testContext.PolicyTemplateFile)' was deployed, but policy definition '$($policyDefinitionResource.name)' was still not found even after $($MaxRetries) retries."
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